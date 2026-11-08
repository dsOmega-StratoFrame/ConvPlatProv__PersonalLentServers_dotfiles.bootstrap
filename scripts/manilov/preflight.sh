#!/usr/bin/env bash
# scripts/manilov/preflight.sh — read-only environment / tool / prerequisite
# gate for the bootstrap-owned @Manilov surfaces.
#
# It never writes: no file is created, no service is touched, no packet is sent.
# Exit status is non-zero if any assertion fails, and every failure names the
# fix. It does not start, stop or reconfigure anything the image applier
# (`manilov-network`) owns (ADR 0006, ADR 0007).
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: preflight.sh [--host HOST] [--host=HOST]

Read-only checks for the bootstrap-owned @Manilov surfaces.

  --host HOST   target host from hosts.ini (default: local)
                Use `local` to check the control node only.

Checks, in order:
  * the repository layout and inventory entry of HOST
  * every variable the other scripts interpolate resolves to an absolute path
  * the bootstrap-owned scripts keep their invariants (set -euo pipefail,
    no `sudo`, the `manilov-network` name)
  * on HOST: uid 0, systemd-networkd, docker + daemon, ip/nft/networkctl/rsync,
    the zterra root, the project directory and /etc/systemd/network
EOF
}

ZTERRA_ROOT=""
PROJECT_DIR=""
COMPOSE_FILE=""
MARKER=""
declare -A HOSTFACT=()
parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
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

step "repository"
require_repo_layout
ok "repository layout present under $MANILOV_REPO_ROOT"

step "inventory"
if host_is_local; then
  info "host is local; skipping the hosts.ini membership check"
elif inventory_has_host "$MANILOV_HOST"; then
  ok "$MANILOV_HOST is declared in hosts.ini"
else
  fail_check "host '$MANILOV_HOST' is not in hosts.ini; add it to [terra] or pass the inventory name (e.g. --host terra-local)"
fi

step "variables"
load_manilov_vars
ZTERRA_ROOT="$(vars_get zterra_root)"
PROJECT_DIR="$(vars_get nixos_container_project_dir)"
COMPOSE_FILE="$(vars_get nixos_container_compose_file)"
MARKER="$(vars_get_optional manilov_network_marker)"
[ -n "$MARKER" ] || MARKER="$MANILOV_DEFAULT_MARKER"
require_safe_value "$ZTERRA_ROOT" "zterra_root"
require_safe_value "$PROJECT_DIR" "project directory"
require_safe_value "$COMPOSE_FILE" "compose path"
require_safe_value "$MARKER" "marker path"

for pair in \
  "zterra_root=$ZTERRA_ROOT" \
  "nixos_container_project_dir=$PROJECT_DIR" \
  "nixos_container_compose_file=$COMPOSE_FILE" \
  "nixos_container_virt_scripts_dir=$(vars_get nixos_container_virt_scripts_dir)" \
  "nixos_container_home_assistant_image=$(vars_get nixos_container_home_assistant_image)" \
  "nixos_container_unix_dotfiles_dir=$(vars_get nixos_container_unix_dotfiles_dir)" \
  "nixos_container_name=$(vars_get nixos_container_name)" \
  "nixos_container_username=$(vars_get nixos_container_username)" \
  "manilov_vm_name=$(vars_get manilov_vm_name)"; do
  name="${pair%%=*}"
  value="${pair#*=}"
  case "$value" in
    /*) pass_check "$name resolves to $value" ;;
    *) fail_check "$name resolves to '$value', which is not an absolute path; fix group_vars" ;;
  esac
done

case "$ZTERRA_ROOT" in
  /) fail_check "zterra_root must not be the root filesystem (the NAS root is too small; see TOS-ZTERRA-002)" ;;
  *) pass_check "zterra_root is $ZTERRA_ROOT" ;;
esac

step "script invariants"
script_files=()
while IFS= read -r file; do
  script_files+=("$file")
done < <(find "$MANILOV_SCRIPTS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)
[ "${#script_files[@]}" -gt 0 ] || fail_check "no scripts found under $MANILOV_SCRIPTS_DIR"
for file in "${script_files[@]}"; do
  base="$(basename "$file")"
  if [ "$base" = "lib.sh" ]; then
    pass_check "$base is the shared library (never executed directly)"
  elif grep -q '^set -euo pipefail$' "$file"; then
    pass_check "$base sets -euo pipefail"
  else
    fail_check "$base is missing 'set -euo pipefail'"
  fi
  if grep -nE '(^|[;&|(])[[:space:]]*sudo[[:space:]]' "$file" >/dev/null; then
    fail_check "$base invokes sudo; the target SSH user is uid 0 and sudo drops privilege"
  else
    pass_check "$base never invokes sudo"
  fi
done
bad_name="manilov-""net"
if grep -rnE "${bad_name}([^w]|\$)" "$MANILOV_SCRIPTS_DIR" "$MANILOV_REPO_ROOT/Makefile.Manilov" >/dev/null 2>&1; then
  fail_check "a script uses '$bad_name' as a name; the applier and its units carry the -network suffix"
else
  pass_check "the manilov-network name is used consistently"
fi

step "local tools"
for tool in bash awk sed grep find sort; do
  if have_cmd "$tool"; then
    pass_check "local $tool present"
  else
    fail_check "local $tool is missing; install it on the control node"
  fi
done
if have_cmd sha256sum || have_cmd shasum; then
  pass_check "local sha256 tool present"
else
  fail_check "neither sha256sum nor shasum is available; the content-tag and drift checks need one"
fi
if host_is_local; then
  for tool in docker ip nft networkctl rsync tar; do
    if have_cmd "$tool"; then
      pass_check "local $tool present"
    else
      warn "local $tool is missing (host-side checks will fail unless --host points at the target)"
    fi
  done
else
  if have_cmd ssh; then
    pass_check "local ssh present"
  else
    fail_check "local ssh is missing; the host-side scripts reach @terra over SSH"
  fi
fi

if host_is_local; then
  step "local prerequisites"
  uid="$(id -u)"
  if [ "$uid" = "0" ]; then
    pass_check "running as uid 0"
  else
    fail_check "running as uid $uid; the networkd relinquish and the rescue address need uid 0 without sudo"
  fi
  if systemctl is-active systemd-networkd >/dev/null 2>&1; then
    pass_check "systemd-networkd is active"
  else
    fail_check "systemd-networkd is not active; the relinquish target does not exist on this host"
  fi
  if [ -d /etc/systemd/network ]; then
    pass_check "/etc/systemd/network present"
  else
    fail_check "/etc/systemd/network is missing; networkd has no per-MAC .network file to relinquish"
  fi
else
  step "host"
  require_host
  facts="$(
    host_sh <<'EOF'
set -u
emit() { printf '%s\t%s\n' "$1" "$2"; }
emit uid "$(id -u 2>/dev/null || echo unknown)"
emit systemctl "$(command -v systemctl >/dev/null 2>&1 && echo yes || echo no)"
emit networkd "$(systemctl is-active systemd-networkd 2>/dev/null || true)"
emit docker "$(command -v docker >/dev/null 2>&1 && echo yes || echo no)"
emit docker_daemon "$(docker info >/dev/null 2>&1 && echo ok || echo fail)"
emit ip "$(command -v ip >/dev/null 2>&1 && echo yes || echo no)"
emit nft "$(command -v nft >/dev/null 2>&1 && echo yes || echo no)"
emit networkctl "$(command -v networkctl >/dev/null 2>&1 && echo yes || echo no)"
emit rsync "$(command -v rsync >/dev/null 2>&1 && echo yes || echo no)"
emit tar "$(command -v tar >/dev/null 2>&1 && echo yes || echo no)"
emit networkd_dir "$(test -d /etc/systemd/network && echo yes || echo no)"
emit networkd_files "$(find /etc/systemd/network -maxdepth 1 -name '*.network' 2>/dev/null | wc -l | tr -d ' ')"
EOF
  )"
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    HOSTFACT["$key"]="$value"
  done <<<"$facts"

  if [ "${HOSTFACT[uid]:-unknown}" = "0" ]; then
    pass_check "the host session is uid 0"
  else
    fail_check "the host session is uid ${HOSTFACT[uid]:-unknown}; on TOS 6 the SSH user must be uid 0 (never sudo)"
  fi
  if [ "${HOSTFACT[systemctl]:-no}" = "yes" ]; then
    pass_check "systemctl present on the host"
  else
    fail_check "systemctl is missing on the host; nothing here can be applied"
  fi
  if [ "${HOSTFACT[networkd]:-}" = "active" ]; then
    pass_check "systemd-networkd is active on the host"
  else
    fail_check "systemd-networkd is '${HOSTFACT[networkd]:-unknown}' on the host; the relinquish requires it"
  fi
  for key in docker ip nft networkctl rsync tar; do
    if [ "${HOSTFACT[$key]:-no}" = "yes" ]; then
      pass_check "host $key present"
    else
      fail_check "host $key is missing; run the Layer-0 bootstrap (make run-terra) first"
    fi
  done
  if [ "${HOSTFACT[docker_daemon]:-fail}" = "ok" ]; then
    pass_check "the Docker daemon answers on the host"
  else
    fail_check "the Docker daemon does not answer on the host; start it and re-run"
  fi
  if [ "${HOSTFACT[networkd_dir]:-no}" = "yes" ]; then
    pass_check "/etc/systemd/network present on the host"
  else
    fail_check "/etc/systemd/network is missing on the host; networkd has no per-MAC .network file to relinquish"
  fi
  if [ "${HOSTFACT[networkd_files]:-0}" -gt 0 ]; then
    pass_check "the host has ${HOSTFACT[networkd_files]} .network file(s)"
  else
    fail_check "no .network files under /etc/systemd/network; the management NIC is not networkd-managed"
  fi

  if host_cmd "test -d '$ZTERRA_ROOT'" >/dev/null 2>&1; then
    pass_check "the zterra root $ZTERRA_ROOT exists"
  else
    fail_check "the zterra root $ZTERRA_ROOT is missing; provision and mount it (TOS-ZTERRA-002 DP1)"
  fi
  if host_cmd "test -d '$PROJECT_DIR'" >/dev/null 2>&1; then
    pass_check "the container project directory $PROJECT_DIR exists"
  else
    warn "$PROJECT_DIR does not exist yet; the container layer has not been deployed (expected on a fresh host)"
  fi
  if host_file_exists "$MARKER"; then
    pass_check "the network marker $MARKER exists"
  else
    warn "the network marker $MARKER is missing; the image applier will fail closed until the host provisions it"
  fi
  if host_cmd "nft list ruleset 2>/dev/null | grep -q INPUT_PROTECT"; then
    pass_check "INPUT_PROTECT is present (host-owned; these scripts never touch it)"
  else
    warn "INPUT_PROTECT was not found in the nft ruleset; confirm the host firewall before the L3 move (ADR 0006 D4)"
  fi
fi

step "result"
finish_checks
