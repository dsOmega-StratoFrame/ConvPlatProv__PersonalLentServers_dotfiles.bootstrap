#!/usr/bin/env bash
# scripts/manilov/host-relinquish.sh — the one-time, reversible hand-off of the
# management uplink from systemd-networkd to the `manilov-network` image applier.
#
# This is the only host-side *network write* the bootstrap owns, and it is
# negative: it writes an `Unmanaged=yes` drop-in on the .network file that
# currently matches the management NIC, discovered from the NIC's permanent MAC.
# It never creates a bridge, moves L3, pins a MAC, writes forwarding rules or
# edits INPUT_PROTECT / DOCKER-* (ADR 0006 D3, D4).
#
# Defaults to dry-run. Requires --apply, and an explicit confirmation.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: host-relinquish.sh [--host HOST] [--marker PATH] [--state-dir PATH]
                          [--iface NAME] [--apply] [--rollback] [--yes]

Dry-run by default. Prints the exact plan; --apply writes it.

  --marker PATH          host marker (default: manilov_network_marker, else
                         /etc/manilov/marker.json)
  --state-dir PATH       host state directory (default: manilov_network_state_dir,
                         else /var/lib/manilov-network)
  --iface NAME           override the discovered management NIC (a diagnostic
                         escape hatch; the default is discovery from the route)
  --apply                perform the write / the rollback
  --rollback             remove the drop-in, reload networkd, verify the uplink
  --yes                  confirm non-interactively (never skips the MAC checks)

Safety: refuses when the discovered permanent MAC equals a peer/router MAC in
the marker, when the NIC is not physical, when br0 already exists, or when the
marker's management MAC disagrees with the host. Never touches nftables.
EOF
}

MARKER=""
STATE_DIR=""
IFACE_OVERRIDE=""
ALLOW_MISSING_MARKER=0
NETFILE=""
DROPIN=""
DROPIN_DIR=""
DROPIN_CONTENT=""
DROPIN_SHA=""
marker_json=""
IFACE=""
MAC=""
MAC_SRC=""

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --marker)
        [ "$#" -ge 2 ] || die "--marker needs a value"
        MARKER="$2"
        shift 2
        ;;
      --marker=*)
        MARKER="${1#*=}"
        shift
        ;;
      --state-dir)
        [ "$#" -ge 2 ] || die "--state-dir needs a value"
        STATE_DIR="$2"
        shift 2
        ;;
      --state-dir=*)
        STATE_DIR="${1#*=}"
        shift
        ;;
      --iface)
        [ "$#" -ge 2 ] || die "--iface needs a value"
        IFACE_OVERRIDE="$2"
        shift 2
        ;;
      --iface=*)
        IFACE_OVERRIDE="${1#*=}"
        shift
        ;;
      --allow-missing-marker)
        ALLOW_MISSING_MARKER=1
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

discover_uplink() {
  host_sh <<'EOF'
set -u
iface=""
if command -v ip >/dev/null 2>&1; then
  iface="$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
  if [ -z "$iface" ]; then
    iface="$(ip -o -4 addr show scope global 2>/dev/null | awk '$2 != "lo" { print $2; exit }')"
  fi
fi
if [ -z "$iface" ]; then
  printf 'ERROR\tno interface carries the default route or a global IPv4 address\n'
  exit 0
fi
mac=""
src=""
if [ -r "/sys/class/net/$iface/permanent_address" ]; then
  mac="$(cat "/sys/class/net/$iface/permanent_address" 2>/dev/null || true)"
  src="sysfs/permanent_address"
fi
case "$mac" in
  "" | 00:00:00:00:00:00)
    if command -v ethtool >/dev/null 2>&1; then
      mac="$(ethtool -P "$iface" 2>/dev/null | awk '/Permanent address/ { print $3; exit }')"
      if [ -n "$mac" ]; then src="ethtool -P"; fi
    fi
    ;;
esac
case "$mac" in
  "" | 00:00:00:00:00:00)
    if command -v networkctl >/dev/null 2>&1; then
      mac="$(networkctl status "$iface" 2>/dev/null | awk -F': *' '/Permanent Address/ { print $2; exit }')"
      if [ -n "$mac" ]; then src="networkctl"; fi
    fi
    ;;
esac
case "$mac" in
  "" | 00:00:00:00:00:00)
    mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)"
    src="sysfs/address (current; the driver exposes no permanent address)"
    ;;
esac
printf '%s\t%s\t%s\n' "$iface" "$mac" "$src"
EOF
}

peer_macs() {
  printf '%s' "$marker_json" \
    | grep -oiE '"(peer|router|gateway)[A-Za-z_]*mac"[[:space:]]*:[[:space:]]*"[0-9a-fA-F:.-]+"' 2>/dev/null \
    | sed -E 's/.*"([0-9a-fA-F:.-]+)"$/\1/' || true
}

find_network_file() {
  local matches=""
  matches="$(host_cmd "grep -ilE '^[[:space:]]*PermanentMACAddress=.*$MAC' /etc/systemd/network/*.network 2>/dev/null || true")"
  if [ -z "$matches" ]; then
    matches="$(host_cmd "grep -ilE '^[[:space:]]*MACAddress=.*$MAC' /etc/systemd/network/*.network 2>/dev/null || true")"
  fi
  if [ -z "$matches" ]; then
    matches="$(host_cmd "grep -ilE '^[[:space:]]*Name=.*$IFACE' /etc/systemd/network/*.network 2>/dev/null || true")"
  fi
  printf '%s' "$matches"
}

find_dropin() {
  host_cmd "ls -1 /etc/systemd/network/*.network.d/50-manilov-unmanaged.conf 2>/dev/null || true"
}

link_is_unmanaged() {
  local setup
  setup="$(host_cmd "networkctl list --no-legend 2>/dev/null | awk '\$2 == \"$IFACE\" { print \$NF }'" || true)"
  case "$setup" in
    *unmanaged*) return 0 ;;
  esac
  return 1
}

require_physical_uplink() {
  if [ "$(host_cmd "test -e '/sys/class/net/$IFACE/device' && printf yes || printf no")" != "yes" ]; then
    die "'$IFACE' is not a physical NIC; refusing to relinquish a bridge, tap, veth or bond member"
  fi
  if host_cmd "test -d '/sys/class/net/$IFACE/bridge'"; then
    die "'$IFACE' is already a bridge; refusing to relinquish it"
  fi
  if host_cmd "test -e /sys/class/net/br0"; then
    die "br0 already exists; the applier has already applied. Run its 'rollback' before relinquishing anything"
  fi
}

check_marker() {
  local marker_mgmt="" peer="" normalized=""

  if ! host_file_exists "$MARKER"; then
    if [ "$ALLOW_MISSING_MARKER" -eq 1 ]; then
      warn "$MARKER is missing; continuing because --allow-missing-marker was passed"
      return 0
    fi
    die "$MARKER is missing; provision the pinned network marker before relinquishing (it is the only mode selector, ADR 0006 D2). Use --allow-missing-marker only for a deliberate pre-marker hand-off"
  fi
  marker_json="$(host_read_file "$MARKER")"
  [ -n "$marker_json" ] || die "$MARKER is empty; the marker must be a valid JSON document"

  marker_mgmt="$(marker_value permanentMac)"
  if [ -n "$marker_mgmt" ]; then
    if ! normalized="$(normalize_mac "$marker_mgmt" 2>/dev/null)"; then
      die "the marker's management permanentMac '$marker_mgmt' is not a MAC address"
    fi
    if [ "$normalized" != "$MAC" ]; then
      die "the marker declares management.permanentMac=$normalized but the uplink carrying the management address has permanent MAC $MAC; fix the marker before relinquishing"
    fi
    pass_check "the marker's management MAC matches the discovered uplink ($MAC)"
  else
    warn "the marker has no management.permanentMac; skipped the cross-check"
  fi

  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    normalized="$(normalize_mac "$peer" 2>/dev/null)" || continue
    if [ "$normalized" = "$MAC" ]; then
      die "refusing: the discovered management MAC $MAC equals the peer/router MAC $peer from $MARKER; the marker and the host disagree about which MAC belongs where"
    fi
  done <<<"$(peer_macs)"
  pass_check "the management MAC differs from every peer/router MAC in the marker"
}

step "inputs"
require_repo_layout
load_manilov_vars
MARKER="$(vars_get_optional manilov_network_marker)"
[ -n "$MARKER" ] || MARKER="$MANILOV_DEFAULT_MARKER"
STATE_DIR="$(vars_get_optional manilov_network_state_dir)"
[ -n "$STATE_DIR" ] || STATE_DIR="$MANILOV_DEFAULT_STATE_DIR"
if [ -n "$IFACE_OVERRIDE" ]; then
  IFACE="$IFACE_OVERRIDE"
fi
require_safe_value "$MARKER" "marker path"
require_safe_value "$STATE_DIR" "state directory"
if [ -n "$IFACE_OVERRIDE" ]; then
  require_safe_value "$IFACE_OVERRIDE" "interface name"
fi
info "marker:    $MARKER"
info "state dir: $STATE_DIR (host $MANILOV_HOST)"
info "mode:      $(if is_apply; then printf 'apply'; else printf 'dry-run (default)'; fi)$(if [ "$ROLLBACK" -eq 1 ]; then printf ' + rollback'; fi)"

step "host access"
require_host
require_host_uid0
for tool in ip networkctl tar grep sed awk; do
  if [ "$(host_cmd "command -v $tool >/dev/null 2>&1 && printf yes || printf no")" = "yes" ]; then
    pass_check "host $tool present"
  else
    fail_check "host $tool is missing; install it or run the Layer-0 bootstrap first"
  fi
done
finish_checks

step "discovery"
if [ -z "$IFACE" ]; then
  discovered="$(discover_uplink)"
  IFACE="$(printf '%s' "$discovered" | cut -f1)"
  MAC="$(printf '%s' "$discovered" | cut -f2)"
  MAC_SRC="$(printf '%s' "$discovered" | cut -f3)"
  case "$IFACE" in
    "" | ERROR*) die "cannot discover the management NIC: ${MAC:-no interface carries the management address}" ;;
  esac
else
  MAC="$(host_cmd "cat '/sys/class/net/$IFACE/permanent_address' 2>/dev/null || cat '/sys/class/net/$IFACE/address' 2>/dev/null" || true)"
  MAC_SRC="explicit --iface"
fi
require_safe_value "$IFACE" "interface name"
MAC_RAW="$MAC"
if ! MAC="$(normalize_mac "$MAC_RAW" 2>/dev/null)"; then
  die "cannot normalize the permanent MAC of $IFACE ('$MAC_RAW'); refusing to guess"
fi
info "management NIC: $IFACE"
info "permanent MAC:  $MAC (from $MAC_SRC)"
require_physical_uplink

step "marker and peers"
check_marker

step "networkd file"
if [ "$ROLLBACK" -eq 1 ]; then
  matches="$(find_dropin)"
  count="$(printf '%s\n' "$matches" | grep -c . || true)"
  case "$count" in
    0)
      info "no 50-manilov-unmanaged.conf under /etc/systemd/network/*.network.d"
      ok "nothing to roll back"
      exit 0
      ;;
    1)
      DROPIN="$matches"
      DROPIN_DIR="$(dirname "$DROPIN")"
      require_safe_value "$DROPIN" "drop-in path"
      info "drop-in: $DROPIN"
      ;;
    *)
      die "$count manilov drop-ins found ($(printf '%s' "$matches" | tr '\n' ' ')); refusing to guess which one to remove"
      ;;
  esac
else
  NETFILE="$(find_network_file)"
  count="$(printf '%s\n' "$NETFILE" | grep -c . || true)"
  case "$count" in
    0)
      die "no /etc/systemd/network/*.network matches $IFACE (permanent MAC $MAC); networkd does not manage this link, so there is nothing to relinquish"
      ;;
    1) : ;;
    *)
      die "$count .network files match $IFACE: $(printf '%s' "$NETFILE" | tr '\n' ' '); refuse to guess which one owns the management address"
      ;;
  esac
  DROPIN_DIR="$NETFILE.d"
  DROPIN="$DROPIN_DIR/50-manilov-unmanaged.conf"
  require_safe_value "$NETFILE" "networkd file"
  require_safe_value "$DROPIN" "drop-in path"
  DROPIN_CONTENT="# Managed by scripts/manilov/host-relinquish.sh (ADR 0006 D3).
# Hands the uplink to the manilov-network image applier.
[Link]
Unmanaged=yes"
  DROPIN_SHA="$(sha256_of_string "$DROPIN_CONTENT")"
  info "networkd file: $NETFILE"
  info "drop-in:       $DROPIN (sha256 $DROPIN_SHA)"
fi

nft_before=""
if [ "$(host_cmd "command -v nft >/dev/null 2>&1 && printf yes || printf no")" = "yes" ]; then
  nft_before="$(host_cmd "nft list ruleset 2>/dev/null | sha256sum | cut -d' ' -f1" || true)"
fi

step "plan"
if [ "$ROLLBACK" -eq 1 ]; then
  plan "rm -f $DROPIN"
  plan "rmdir $DROPIN_DIR (only when empty)"
  plan "networkctl reload"
  plan "verify that $IFACE is managed again and regains an address"
  plan "nftables: untouched (INPUT_PROTECT and DOCKER-* stay host-owned)"
else
  if host_file_exists "$DROPIN"; then
    remote_sha="$(host_cmd "sha256sum '$DROPIN' 2>/dev/null | cut -d' ' -f1" || true)"
    recorded="$(host_read_file "$STATE_DIR/host-relinquish/relinquish.state")"
    recorded_dropin="$(printf '%s\n' "$recorded" | awk -F= '$1 == "dropin" { print $2; exit }')"
    recorded_sha="$(printf '%s\n' "$recorded" | awk -F= '$1 == "dropin_sha256" { print $2; exit }')"
    if [ "$remote_sha" = "$DROPIN_SHA" ] &&
      [ "$recorded_dropin" = "$DROPIN" ] &&
      [ "$recorded_sha" = "$DROPIN_SHA" ] &&
      link_is_unmanaged; then
      ok "already relinquished: $DROPIN matches the recorded path and hash, and $IFACE is unmanaged"
      exit 0
    fi
    plan "overwrite $DROPIN (the recorded state or the live link does not match)"
  else
    plan "mkdir -p $DROPIN_DIR"
    plan "write $DROPIN:"
    printf '%s\n' "$DROPIN_CONTENT" | sed 's/^/        /' >&2
  fi
  plan "archive /etc/systemd/network -> $STATE_DIR/host-relinquish/network.<UTC>.tar.gz"
  plan "networkctl reload"
  plan "record interface, permanent MAC, file, drop-in hash and archive in $STATE_DIR/host-relinquish/relinquish.state"
  plan "verify that $IFACE is unmanaged (the management address will drop; SSH may disconnect)"
  plan "nftables: untouched (INPUT_PROTECT and DOCKER-* stay host-owned)"
fi

require_apply
if [ "$ROLLBACK" -eq 1 ]; then
  confirm "Remove $DROPIN and hand $IFACE ($MAC) back to systemd-networkd?"
else
  confirm "Relinquish systemd-networkd ownership of $IFACE ($MAC) via $DROPIN? The management address will be released, so this SSH session may drop."
fi

if [ "$ROLLBACK" -eq 1 ]; then
  step "rollback"
  host_cmd "rm -f '$DROPIN'" || die "cannot remove $DROPIN on the host"
  host_cmd "rmdir '$DROPIN_DIR' 2>/dev/null || true"
  if ! host_cmd "networkctl reload"; then
    warn "networkctl reload did not return cleanly; verifying the link state anyway"
  fi
  ok "removed $DROPIN and reloaded networkd"

  waited=0
  managed=0
  while [ "$waited" -lt 30 ]; do
    setup="$(host_cmd "networkctl list --no-legend 2>/dev/null | awk '\$2 == \"$IFACE\" { print \$NF }'" || true)"
    case "$setup" in
      "" | unmanaged) : ;;
      *)
        managed=1
        break
        ;;
    esac
    waited=$((waited + 1))
    sleep 1
  done
  if [ "$managed" -eq 1 ]; then
    pass_check "$IFACE is managed by systemd-networkd again"
  else
    fail_check "$IFACE is still unmanaged after 30s; restore /etc/systemd/network from the archive under $STATE_DIR/host-relinquish"
  fi
  if host_cmd "ip -4 addr show dev '$IFACE' 2>/dev/null | grep -q 'inet '"; then
    pass_check "$IFACE regained an IPv4 address"
  else
    fail_check "$IFACE has no IPv4 address after the rollback; check the DHCP lease and 'networkctl status $IFACE'"
  fi
  step "result"
  finish_checks
  exit 0
fi

step "apply"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$STATE_DIR/host-relinquish/network.$ts.tar.gz"
host_cmd "mkdir -p '$STATE_DIR/host-relinquish'" || die "cannot create $STATE_DIR/host-relinquish on the host"
host_cmd "tar -C /etc/systemd -czf '$archive' network" || die "cannot archive /etc/systemd/network to $archive"
ok "archive: $archive"

host_sh <<EOF_MANILOV
set -eu
cat > '$STATE_DIR/host-relinquish/relinquish.state' <<'STATE'
timestamp=$ts
interface=$IFACE
permanent_mac=$MAC
mac_source=$MAC_SRC
network_file=$NETFILE
dropin=$DROPIN
dropin_sha256=$DROPIN_SHA
archive=$archive
STATE
EOF_MANILOV
ok "recorded $STATE_DIR/host-relinquish/relinquish.state"

host_sh <<EOF_MANILOV
set -eu
mkdir -p '$DROPIN_DIR'
cat > '$DROPIN' <<'CONF'
$DROPIN_CONTENT
CONF
chmod 0644 '$DROPIN'
EOF_MANILOV
ok "wrote $DROPIN"

if ! host_cmd "networkctl reload"; then
  warn "networkctl reload did not return cleanly; the management address may already have been released, which drops this SSH channel"
else
  ok "networkctl reload requested"
fi

if ! host_cmd "true" >/dev/null 2>&1; then
  warn "SSH to $MANILOV_HOST was lost right after the reload; that is the expected consequence of releasing the management address"
else
  if link_is_unmanaged; then
    pass_check "$IFACE is unmanaged (the applier can now own the uplink)"
  else
    fail_check "$IFACE is still managed after 'networkctl reload'; inspect 'networkctl status $IFACE' (the drop-in is $DROPIN)"
  fi
  if host_cmd "ip -4 addr show dev '$IFACE' 2>/dev/null | grep -q 'inet '"; then
    fail_check "$IFACE still holds an IPv4 address; the applier's bridge check would fail closed on a conflicting L3 owner (exit 6)"
  else
    pass_check "$IFACE holds no IPv4 address"
  fi
fi

if [ -n "$nft_before" ]; then
  nft_after="$(host_cmd "nft list ruleset 2>/dev/null | sha256sum | cut -d' ' -f1" || true)"
  if [ -n "$nft_after" ] && [ "$nft_before" != "$nft_after" ]; then
    die "the nftables ruleset changed during the relinquish; the host owns INPUT_PROTECT and DOCKER-*, and this script must never touch them"
  fi
  pass_check "nftables was not modified"
fi

step "result"
ok "relinquished $IFACE ($MAC)"
info "roll back with: make -f Makefile.Manilov host-relinquish ARGS='--rollback --apply'"
finish_checks
