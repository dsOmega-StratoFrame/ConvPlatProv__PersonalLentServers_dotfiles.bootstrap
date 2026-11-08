#!/usr/bin/env bash
# scripts/manilov/host-rescue.sh — install/remove the bootstrap-owned rescue
# path: a systemd timer that re-asserts a static address on the *unconnected*
# second NIC.
#
# It is a safety net, not a datapath owner (ADR 0006 D5): it never adds a route,
# never touches the management uplink, never touches the VM path, and never
# fights the `manilov-network` applier. Defaults to dry-run; --apply installs or
# removes it. Idempotent in both directions.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: host-rescue.sh [--host HOST] [--address CIDR] [--iface NAME]
                      [--interval SPAN] [--apply] [--rollback] [--yes]

Dry-run by default. --apply installs (or, with --rollback, removes).

  --address CIDR   static rescue address, e.g. 192.0.2.10/24
                   (default: manilov_host_rescue_address)
  --iface NAME     the unconnected NIC (default: manilov_host_rescue_interface,
                   else eth0)
  --interval SPAN  timer interval (default: 5min)
  --apply          install/remove the units
  --rollback       stop, disable and remove the units and the address

Refuses when the rescue NIC is the management uplink, a bridge/tap, or has a
default route. The management uplink and the VM path are never touched.

The ADR 0006 D5 'rolled-back' restore of the relinquished .network file is the
`host-relinquish --rollback` step, not this timer: this unit only holds the eth0
address and never edits the management uplink.
EOF
}

ADDRESS=""
RESCUE_IF=""
INTERVAL="5min"
STATE_DIR=""
IP_BIN=""
TS=""
SERVICE="manilov-network-host-rescue.service"
TIMER="manilov-network-host-rescue.timer"
SERVICE_PATH="/etc/systemd/system/manilov-network-host-rescue.service"
TIMER_PATH="/etc/systemd/system/manilov-network-host-rescue.timer"

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address)
        [ "$#" -ge 2 ] || die "--address needs a value"
        ADDRESS="$2"
        shift 2
        ;;
      --address=*)
        ADDRESS="${1#*=}"
        shift
        ;;
      --iface)
        [ "$#" -ge 2 ] || die "--iface needs a value"
        RESCUE_IF="$2"
        shift 2
        ;;
      --iface=*)
        RESCUE_IF="${1#*=}"
        shift
        ;;
      --interval)
        [ "$#" -ge 2 ] || die "--interval needs a value"
        INTERVAL="$2"
        shift 2
        ;;
      --interval=*)
        INTERVAL="${1#*=}"
        shift
        ;;
      --host)
        [ "$#" -ge 2 ] || die "--host needs a value"
        MANILOV_HOST="$2"
        shift 2
        ;;
      --host=*)
        MANILOV_HOST="${1#*=}"
        shift
        ;;
      *)
        rest+=("$1")
        shift
        ;;
    esac
  done
  if [ "${#rest[@]}" -gt 0 ]; then
    parse_common_args "${rest[@]}"
  fi
  require_safe_value "$MANILOV_HOST" "host"
}

parse_script_args "$@"

render_units() {
  cat >"$WORK/$SERVICE" <<EOF
[Unit]
Description=@Manilov host rescue address on $RESCUE_IF (bootstrap-owned; no VM path)
After=network.target

[Service]
Type=oneshot
ExecStart=$IP_BIN address replace $ADDRESS dev $RESCUE_IF
EOF
  cat >"$WORK/$TIMER" <<EOF
[Unit]
Description=@Manilov host rescue timer (bootstrap-owned; no VM path)

[Timer]
OnBootSec=2min
OnUnitActiveSec=$INTERVAL
Unit=$SERVICE
Persistent=false

[Install]
WantedBy=timers.target
EOF
}

install_unit() {
  local local_file="$1" remote="$2" current_sha wanted_sha tmp
  wanted_sha="$(sha256_of_file "$local_file")"
  current_sha="$(host_cmd "sha256sum '$remote' 2>/dev/null | cut -d' ' -f1" || true)"
  if [ "$current_sha" = "$wanted_sha" ]; then
    info "$remote is up to date"
    return 0
  fi
  if host_file_exists "$remote"; then
    host_cmd "cp -a '$remote' '$STATE_DIR/host-rescue/backup.$TS/$(basename "$remote")'" ||
      die "cannot back up $remote"
  fi
  tmp="$remote.tmp.$TS"
  host_write_file "$tmp" <"$local_file" || die "cannot write $tmp on the host"
  host_cmd "chmod 0644 '$tmp' && mv -f '$tmp' '$remote'" || die "cannot install $remote"
  ok "installed $remote"
}

step "inputs"
require_repo_layout
load_manilov_vars
make_workdir
STATE_DIR="$(vars_get_optional manilov_network_state_dir)"
[ -n "$STATE_DIR" ] || STATE_DIR="$MANILOV_DEFAULT_STATE_DIR"
if [ -z "$RESCUE_IF" ]; then
  RESCUE_IF="$(vars_get_optional manilov_host_rescue_interface)"
fi
[ -n "$RESCUE_IF" ] || RESCUE_IF="eth0"
if [ -z "$ADDRESS" ]; then
  ADDRESS="${MANILOV_RESCUE_ADDRESS:-}"
fi
if [ -z "$ADDRESS" ]; then
  ADDRESS="$(vars_get_optional manilov_host_rescue_address)"
fi
require_safe_value "$STATE_DIR" "state directory"
require_safe_value "$RESCUE_IF" "rescue interface"
require_safe_value "$INTERVAL" "interval"

case "$INTERVAL" in
  *[!0-9smindwh]*) die "interval '$INTERVAL' is not a systemd time span (e.g. 5min, 30s, 1h)" ;;
  [0-9]*) : ;;
  *) die "interval '$INTERVAL' must start with a number (e.g. 5min)" ;;
esac

if [ "$ROLLBACK" -eq 0 ] && [ -z "$ADDRESS" ]; then
  die "no rescue address: set manilov_host_rescue_address in group_vars/manilov/vars.yml, export MANILOV_RESCUE_ADDRESS, or pass --address <cidr>"
fi
if [ -n "$ADDRESS" ]; then
  require_safe_value "$ADDRESS" "rescue address"
  validate_cidr "$ADDRESS" || die "'$ADDRESS' is not an IPv4 CIDR (e.g. 192.0.2.10/24)"
fi

info "host:     $MANILOV_HOST"
info "interface: $RESCUE_IF"
info "address:  ${ADDRESS:-<not set>}"
info "interval: $INTERVAL"
info "mode:     $(if is_apply; then printf 'apply'; else printf 'dry-run (default)'; fi)$(if [ "$ROLLBACK" -eq 1 ]; then printf ' + rollback'; fi)"

step "host access"
require_host
require_host_uid0
for tool in ip systemctl; do
  if [ "$(host_cmd "command -v $tool >/dev/null 2>&1 && printf yes || printf no")" = "yes" ]; then
    pass_check "host $tool present"
  else
    fail_check "host $tool is missing; the rescue unit needs it"
  fi
done
finish_checks
IP_BIN="$(host_cmd 'command -v ip')" || die "cannot resolve the host's ip binary"
require_safe_value "$IP_BIN" "ip path"

if [ "$ROLLBACK" -eq 1 ] && [ -z "$ADDRESS" ] && host_file_exists "$SERVICE_PATH"; then
  ADDRESS="$(host_read_file "$SERVICE_PATH" | awk '/^ExecStart=/ { for (i = 1; i <= NF; i++) if ($i == "replace") { print $(i + 1); exit } }')"
  if [ -n "$ADDRESS" ]; then
    validate_cidr "$ADDRESS" || die "the installed $SERVICE has an unparsable address '$ADDRESS'; remove $SERVICE_PATH by hand"
    info "recovered the address from $SERVICE_PATH: $ADDRESS"
  fi
fi

step "guards"
if [ "$(host_cmd "test -e '/sys/class/net/$RESCUE_IF' && printf yes || printf no")" != "yes" ]; then
  die "interface '$RESCUE_IF' does not exist on the host; the rescue path needs the unconnected second NIC"
fi
mgmt_if="$(host_sh <<'EOF'
set -u
ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
EOF
)"
if [ -n "$mgmt_if" ] && [ "$mgmt_if" = "$RESCUE_IF" ]; then
  die "refusing: '$RESCUE_IF' carries the management default route; the rescue must never touch the management uplink (ADR 0006 D5)"
fi
if host_cmd "test -d '/sys/class/net/$RESCUE_IF/bridge'"; then
  die "refusing: '$RESCUE_IF' is a bridge"
fi
case "$RESCUE_IF" in
  br0 | tap0 | docker0 | virbr0)
    die "refusing: '$RESCUE_IF' is the applier's or Docker's virtual device, not the physical rescue NIC"
    ;;
esac
if [ "$(host_cmd "test -e '/sys/class/net/$RESCUE_IF/device' && printf yes || printf no")" != "yes" ]; then
  die "refusing: '$RESCUE_IF' is not a physical NIC"
fi
pass_check "'$RESCUE_IF' is a physical NIC and is not the management uplink (${mgmt_if:-none})"

step "units"
render_units
info "planned $SERVICE_PATH:"
sed 's/^/    /' "$WORK/$SERVICE" >&2
info "planned $TIMER_PATH:"
sed 's/^/    /' "$WORK/$TIMER" >&2

if [ "$ROLLBACK" -eq 1 ]; then
  plan "systemctl disable --now $TIMER (tolerate not-installed)"
  plan "systemctl stop $SERVICE (tolerate not-installed)"
  plan "rm -f $TIMER_PATH $SERVICE_PATH"
  plan "systemctl daemon-reload"
  plan "$IP_BIN address del $ADDRESS dev $RESCUE_IF (tolerate already absent)"
  plan "verify that $RESCUE_IF no longer holds $ADDRESS"
else
  plan "install $SERVICE_PATH and $TIMER_PATH (backup first, mode 0644)"
  plan "systemctl daemon-reload"
  plan "systemctl enable --now $TIMER"
  plan "systemctl start $SERVICE (apply the address now)"
  plan "verify that $RESCUE_IF holds $ADDRESS"
  plan "does not add a route and does not touch ${mgmt_if:-the management uplink} or the VM path"
fi

require_apply

TS="$(date -u +%Y%m%dT%H%M%SZ)"
host_cmd "mkdir -p '$STATE_DIR/host-rescue/backup.$TS'" || die "cannot create the rescue state directory"
host_cmd "mkdir -p /etc/systemd/system" || die "cannot reach /etc/systemd/system on the host"

if [ "$ROLLBACK" -eq 1 ]; then
  step "rollback"
  host_cmd "systemctl disable --now '$TIMER' >/dev/null 2>&1 || true"
  host_cmd "systemctl stop '$SERVICE' >/dev/null 2>&1 || true"
  host_cmd "rm -f '$TIMER_PATH' '$SERVICE_PATH'" || die "cannot remove the rescue units"
  host_cmd "systemctl daemon-reload" || die "systemctl daemon-reload failed"
  host_cmd "$IP_BIN address del '$ADDRESS' dev '$RESCUE_IF' >/dev/null 2>&1 || true"
  ok "removed the rescue timer, the service and the address"

  if [ -n "$ADDRESS" ]; then
    if host_cmd "ip -4 addr show dev '$RESCUE_IF' 2>/dev/null | grep -qF '$ADDRESS'"; then
      fail_check "$RESCUE_IF still holds $ADDRESS; remove it manually with '$IP_BIN address del $ADDRESS dev $RESCUE_IF'"
    else
      pass_check "$RESCUE_IF no longer holds $ADDRESS"
    fi
  else
    warn "no rescue address was recorded; only the units were removed"
  fi
  if [ "$(host_cmd "systemctl is-enabled '$TIMER' 2>/dev/null || true")" = "enabled" ]; then
    fail_check "$TIMER is still enabled"
  else
    pass_check "$TIMER is not enabled"
  fi
  step "result"
  finish_checks
  exit 0
fi

step "install"
install_unit "$WORK/$SERVICE" "$SERVICE_PATH"
install_unit "$WORK/$TIMER" "$TIMER_PATH"

host_cmd "systemctl daemon-reload" || die "systemctl daemon-reload failed"
host_cmd "systemctl enable --now '$TIMER'" || die "cannot enable/start $TIMER"
host_cmd "systemctl start '$SERVICE'" || die "cannot start $SERVICE"
ok "the rescue timer is enabled and the address was applied"

if host_cmd "ip -4 addr show dev '$RESCUE_IF' 2>/dev/null | grep -qF '$ADDRESS'"; then
  pass_check "$RESCUE_IF holds $ADDRESS"
else
  fail_check "$RESCUE_IF does not hold $ADDRESS; inspect 'systemctl status $SERVICE'"
fi
if [ "$(host_cmd "systemctl is-enabled '$TIMER' 2>/dev/null || true")" = "enabled" ]; then
  pass_check "$TIMER is enabled"
else
  fail_check "$TIMER is not enabled"
fi

step "result"
ok "rescue path installed on $RESCUE_IF"
info "roll back with: make -f Makefile.Manilov host-rescue ARGS='--rollback --apply'"
finish_checks
