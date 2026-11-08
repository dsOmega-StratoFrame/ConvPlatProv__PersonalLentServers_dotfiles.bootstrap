#!/usr/bin/env bash
# scripts/manilov/verify.sh — read-only end-to-end verification of the
# bootstrap-owned @Manilov surfaces.
#
# It aggregates preflight, image-check and libvirt-check, then inspects the host
# relinquish state, the rescue unit and (when the image provides it) the
# `manilov-network` applier's read-only `check`/`status`. It never writes and
# never runs a mutating applier verb.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: verify.sh [--host HOST] [--strict] [--applier PATH]

Read-only end-to-end check. Exits non-zero on any failed assertion.

  --host HOST      target host from hosts.ini (default: local)
  --strict         treat a missing `manilov-network` applier as a failure
  --applier PATH   applier binary inside the container
                   (default: /run/current-system/sw/bin/manilov-network)

verify never accepts --apply: the applier owns the datapath, and its mutating
verbs are not reachable from this repo.
EOF
}

STRICT=0
APPLIER="/run/current-system/sw/bin/manilov-network"
CONTAINER=""
MARKER=""
STATE_DIR=""
RESCUE_IF=""
RESCUE_ADDR=""
marker_json=""

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --strict)
        STRICT=1
        shift
        ;;
      --applier)
        [ "$#" -ge 2 ] || die "--applier needs a value"
        APPLIER="$2"
        shift 2
        ;;
      --applier=*)
        APPLIER="${1#*=}"
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
  if is_apply; then
    die "verify is read-only; --apply is not accepted (use the owning step for changes)"
  fi
  require_safe_value "$MANILOV_HOST" "host"
  require_safe_value "$APPLIER" "applier path"
}

parse_script_args "$@"

run_sub() {
  local name="$1"
  step "$name"
  if bash "$MANILOV_SCRIPTS_DIR/$name" --host "$MANILOV_HOST"; then
    pass_check "$name"
  else
    fail_check "$name reported a failure (see its output above)"
  fi
}

relinquish_dropins() {
  host_sh <<'EOF'
set -u
found=0
for f in /etc/systemd/network/*.network.d/*.conf /etc/systemd/network/*.network; do
  [ -f "$f" ] || continue
  if grep -qE '^[[:space:]]*Unmanaged=yes' "$f" 2>/dev/null; then
    printf '%s\n' "$f"
    found=1
  fi
done
[ "$found" -eq 1 ] || true
EOF
}

step "inputs"
require_repo_layout
load_manilov_vars
make_workdir
CONTAINER="$(vars_get nixos_container_name)"
MARKER="$(vars_get_optional manilov_network_marker)"
STATE_DIR="$(vars_get_optional manilov_network_state_dir)"
RESCUE_IF="$(vars_get_optional manilov_host_rescue_interface)"
RESCUE_ADDR="$(vars_get_optional manilov_host_rescue_address)"
[ -n "$MARKER" ] || MARKER="$MANILOV_DEFAULT_MARKER"
[ -n "$STATE_DIR" ] || STATE_DIR="$MANILOV_DEFAULT_STATE_DIR"
[ -n "$RESCUE_IF" ] || RESCUE_IF="eth0"
require_safe_value "$CONTAINER" "container name"
require_safe_value "$MARKER" "marker path"
require_safe_value "$STATE_DIR" "state directory"
require_safe_value "$RESCUE_IF" "rescue interface"
if [ -n "$RESCUE_ADDR" ]; then
  require_safe_value "$RESCUE_ADDR" "rescue address"
fi

run_sub preflight.sh
run_sub image-check.sh
run_sub libvirt-check.sh

step "network marker and host relinquish"
require_host
require_host_uid0
if host_file_exists "$MARKER"; then
  marker_json="$(host_read_file "$MARKER")"
  profile="$(marker_value profile)"
  role="$(marker_value role)"
  if [ -n "$profile" ]; then
    pass_check "marker declares profile '$profile' and role '${role:-unknown}'"
  else
    fail_check "$MARKER has no 'profile'; the applier will fail closed"
  fi
else
  profile=""
  warn "$MARKER is missing; the image applier fails closed and the relinquish state cannot be verified"
fi

dropins="$(relinquish_dropins)"
case "$profile" in
  bridge)
    if [ -n "$dropins" ]; then
      pass_check "the host relinquished the uplink ($(printf '%s' "$dropins" | tr '\n' ' '))"
    else
      fail_check "profile is bridge but no systemd-networkd Unmanaged=yes drop-in exists; run 'make -f Makefile.Manilov host-relinquish ARGS=--apply'"
    fi
    ;;
  proxyarp)
    if [ -n "$dropins" ]; then
      fail_check "profile is proxyarp but the host relinquished an uplink ($dropins); roll it back with 'make -f Makefile.Manilov host-relinquish ARGS=--rollback'"
    else
      pass_check "profile is proxyarp and the host still manages its uplinks"
    fi
    ;;
  "")
    warn "skipped the relinquish assertion (no marker profile)"
    ;;
  *)
    fail_check "marker profile '$profile' is not one of proxyarp|bridge"
    ;;
esac

state_json="$(host_read_file "$STATE_DIR/state.json")"
applier_phase=""
if [ -n "$state_json" ]; then
  applier_phase="$(printf '%s\n' "$state_json" | grep -oE '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
fi
if [ -z "$state_json" ]; then
  info "no applier state at $STATE_DIR/state.json (the network module may not be deployed yet)"
elif [ "$applier_phase" = "rolled-back" ] && [ -n "$dropins" ]; then
  fail_check "the applier is rolled-back (handoff.to=host) but the Unmanaged drop-in is still present; restore host ownership with 'make -f Makefile.Manilov host-relinquish ARGS=\"--rollback --apply\"'"
else
  info "applier phase: ${applier_phase:-unknown}"
fi

step "host rescue"
timer_state="$(host_cmd "systemctl is-enabled manilov-network-host-rescue.timer 2>/dev/null || true")"
timer_active="$(host_cmd "systemctl is-active manilov-network-host-rescue.timer 2>/dev/null || true")"
case "$timer_state" in
  enabled | enabled-runtime)
    if [ "$timer_active" = "active" ]; then
      pass_check "manilov-network-host-rescue.timer is enabled and active"
    else
      fail_check "manilov-network-host-rescue.timer is enabled but '$timer_active'; start it with 'make -f Makefile.Manilov host-rescue ARGS=--apply'"
    fi
    if [ -n "$RESCUE_ADDR" ]; then
      if host_cmd "ip -4 addr show dev '$RESCUE_IF' 2>/dev/null | grep -q '${RESCUE_ADDR%/*}/'" >/dev/null 2>&1; then
        pass_check "the rescue address $RESCUE_ADDR is present on $RESCUE_IF"
      else
        fail_check "the rescue address $RESCUE_ADDR is not on $RESCUE_IF; run the rescue service ('systemctl start manilov-network-host-rescue.service' on the host)"
      fi
    else
      warn "no manilov_host_rescue_address is configured; the rescue timer has nothing to assert"
    fi
    ;;
  *)
    if [ "$profile" = "bridge" ] && [ -n "$dropins" ]; then
      fail_check "the uplink is relinquished but no rescue timer is installed; install it with 'make -f Makefile.Manilov host-rescue ARGS=--apply' (ADR 0006 D5)"
    else
      warn "manilov-network-host-rescue.timer is not installed (state '${timer_state:-unknown}')"
    fi
    ;;
esac

step "manilov-network applier (read-only)"
if [ "$(ctr_sh "$CONTAINER" <<EOF
PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/usr/bin:/bin
export PATH
command -v manilov-network >/dev/null 2>&1 && printf yes || printf no
EOF
)" = "yes" ]; then
  if ctr_sh "$CONTAINER" <<EOF
PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/usr/bin:/bin
export PATH
'$APPLIER' check
EOF
  then
    pass_check "manilov-network check passed"
  else
    fail_check "manilov-network check failed; run it in the container for the exit code (3 marker, 4 identity, 5 uplink, 6 conflict, 7 host precondition, 8 schema)"
  fi
  if ctr_sh "$CONTAINER" <<EOF
PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/usr/bin:/bin
export PATH
'$APPLIER' status
EOF
  then
    pass_check "manilov-network status is clean"
  else
    if [ "$STRICT" -eq 1 ]; then
      fail_check "manilov-network status is degraded or not applied"
    else
      warn "manilov-network status is not clean (degraded or not applied yet); the applier owns the repair"
    fi
  fi
else
  if [ "$STRICT" -eq 1 ]; then
    fail_check "$APPLIER is not present in $CONTAINER; --strict requires the applier"
  else
    warn "$APPLIER is not present in $CONTAINER; skipped the applier check (the image predates the network module)"
  fi
fi

step "result"
finish_checks
