#!/usr/bin/env bash
# shellcheck disable=SC2034
# scripts/manilov/lib.sh — shared helpers for the bootstrap-owned @Manilov
# network/lifecycle surfaces.
#
# The datapath (br0, uplink enslavement, the L3 move, the MAC pin, tap0/proxyARP,
# IPv4 forwarding, the VM-path nftables rules, the tap attachment, the dead-man)
# is owned by the image applier `manilov-network` (ADR 0006, ADR 0007). These
# helpers exist only for the host-side surfaces the bootstrap owns: preflight,
# image/bind checks, the one-time networkd relinquish and the eth0 rescue.
#
# No helper here invokes sudo: on @terra the SSH account is already uid 0 and
# `sudo` drops privilege to the unprivileged `root` account (ADR 0003).

MANILOV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANILOV_SCRIPTS_DIR="$MANILOV_LIB_DIR"
MANILOV_REPO_ROOT="$(cd "$MANILOV_LIB_DIR/../.." && pwd)"

SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-$0}" .sh)}"

MANILOV_DEFAULT_MARKER="/etc/manilov/marker.json"
MANILOV_DEFAULT_STATE_DIR="/var/lib/manilov-network"
MANILOV_HOST="${MANILOV_HOST:-local}"
MANILOV_SSH_TIMEOUT="${MANILOV_SSH_TIMEOUT:-10}"
APPLY="${APPLY:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
ROLLBACK="${ROLLBACK:-0}"
WORK=""
failures=0
declare -A VARS=()
declare -A STRATEGY=()

# --- logging -----------------------------------------------------------------

info() { printf '[manilov:%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
ok() { printf '[manilov:%s] OK: %s\n' "$SCRIPT_NAME" "$*" >&2; }
warn() { printf '[manilov:%s] WARN: %s\n' "$SCRIPT_NAME" "$*" >&2; }
error() { printf '[manilov:%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; }
step() { printf '\n==> [%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }

die() {
  error "$*"
  exit "${MANILOV_EXIT:-1}"
}

plan() { printf '    PLAN  %s\n' "$*" >&2; }

pass_check() { ok "$*"; }
fail_check() {
  error "FAILED: $*"
  failures=$((failures + 1))
}

finish_checks() {
  if [ "$failures" -ne 0 ]; then
    die "$failures check(s) failed"
  fi
  ok "all checks passed"
}

# --- process / argument helpers ----------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local c
  for c in "$@"; do
    have_cmd "$c" || die "required command not found: $c (install it on this machine; these scripts never use sudo)"
  done
}

is_apply() { [ "$APPLY" -eq 1 ]; }

require_apply() {
  if ! is_apply; then
    info "dry-run (default): nothing was changed. Re-run with --apply to execute the plan above."
    exit 0
  fi
}

confirm() {
  local prompt="$1" answer=""
  if [ "$ASSUME_YES" -eq 1 ]; then
    info "confirmed (--yes): $prompt"
    return 0
  fi
  if [ ! -t 0 ]; then
    die "refusing to prompt without a TTY; pass --yes to confirm non-interactively: $prompt"
  fi
  printf '%s [y/N] ' "$prompt" >&2
  read -r answer
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
    *) die "aborted by the operator" ;;
  esac
}

require_uid0() {
  local uid
  uid="$(id -u)"
  [ "$uid" = "0" ] || die "this step must run as the uid-0 account (uid is $uid); do not use sudo, which drops privilege to the unprivileged root account"
}

# Values interpolated into remote shell snippets must be unambiguous. Paths,
# MACs, CIDRs and container names all fit this set.
require_safe_value() {
  local value="$1" what="$2"
  case "$value" in
    "" | *[!A-Za-z0-9_./:@+,=-]*)
      die "refusing to use $what '$value': expected only [A-Za-z0-9_./:@+,=-] (fix the source variable)"
      ;;
  esac
}

# Handles the options shared by every script. Script-specific options are
# extracted by the script itself before this is called; call `usage` from the
# script so --help has something to print.
parse_common_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host)
        [ "$#" -ge 2 ] || die "--host needs a value (e.g. --host terra-local or --host local)"
        MANILOV_HOST="$2"
        shift 2
        ;;
      --host=*)
        MANILOV_HOST="${1#*=}"
        shift
        ;;
      --apply)
        APPLY=1
        shift
        ;;
      --dry-run)
        APPLY=0
        shift
        ;;
      --yes | -y)
        ASSUME_YES=1
        shift
        ;;
      --rollback)
        ROLLBACK=1
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (see --help)"
        ;;
    esac
  done
  require_safe_value "$MANILOV_HOST" "host"
}

make_workdir() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/manilov.XXXXXX")"
  trap cleanup_workdir EXIT
}

cleanup_workdir() {
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}

# --- host access -------------------------------------------------------------
# Every script runs on the control node. Host-side work goes through `host_sh`
# (a shell program on stdin, so no nested quoting) or `host_cmd` (one command).
# `--host local` keeps everything on this machine.

host_is_local() {
  case "$MANILOV_HOST" in
    "" | local | localhost | 127.0.0.1 | ::1) return 0 ;;
  esac
  return 1
}

host_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout="$MANILOV_SSH_TIMEOUT" "$MANILOV_HOST" "$@"
}

host_sh() {
  if host_is_local; then
    bash -s
    return
  fi
  require_cmd ssh
  host_ssh bash -s
}

host_cmd() {
  if host_is_local; then
    bash -c "$*"
    return
  fi
  require_cmd ssh
  host_ssh "$*"
}

require_host() {
  if host_is_local; then
    return 0
  fi
  require_cmd ssh
  ssh -o BatchMode=yes -o ConnectTimeout="$MANILOV_SSH_TIMEOUT" "$MANILOV_HOST" true </dev/null >/dev/null 2>&1 ||
    die "cannot reach host '$MANILOV_HOST' over SSH (BatchMode). Check hosts.ini and ~/.ssh/config; no sudo is used."
}

require_host_uid0() {
  local uid
  uid="$(host_cmd 'id -u')"
  [ "$uid" = "0" ] || die "the target session runs as uid $uid, not 0; on @terra the SSH user is uid 0 and sudo would drop privilege"
}

host_file_exists() {
  local path="$1" answer
  require_safe_value "$path" path
  answer="$(host_cmd "test -e '$path' && printf yes || printf no")"
  [ "$answer" = "yes" ]
}

host_read_file() {
  local path="$1"
  require_safe_value "$path" path
  host_cmd "cat '$path' 2>/dev/null" || true
}

host_file_size() {
  local path="$1"
  require_safe_value "$path" path
  host_cmd "stat -c %s '$path' 2>/dev/null || printf 0"
}

# Write stdin to a path on the host (used for rendered unit/compose files).
host_write_file() {
  local path="$1"
  require_safe_value "$path" path
  if host_is_local; then
    cat >"$path"
    return
  fi
  require_cmd ssh
  host_ssh "cat > '$path'"
}

# Run a shell program inside the @NikolaiGogol system container, on stdin, so
# container-side commands need no nested quoting.
ctr_sh() {
  local ctr="$1"
  require_safe_value "$ctr" "container name"
  if host_is_local; then
    require_cmd docker
    docker exec -i "$ctr" sh -s
    return
  fi
  require_cmd ssh
  host_ssh "docker exec -i '$ctr' sh -s"
}

# --- inventory / vars --------------------------------------------------------

require_repo_layout() {
  local rel
  for rel in \
    hosts.ini \
    group_vars/terra/vars.yml \
    group_vars/nikolaigogol/vars.yml \
    group_vars/manilov/vars.yml \
    roles/nixos_container/defaults/main.yml \
    roles/nixos_container/templates/docker-compose-system.yml.j2; do
    [ -e "$MANILOV_REPO_ROOT/$rel" ] || die "missing repo file: $rel (run from the bootstrap repository)"
  done
}

inventory_has_host() {
  local host="$1"
  awk -v h="$host" '
    /^\[/ { gsub(/[][]/, ""); next }
    $1 == h { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$MANILOV_REPO_ROOT/hosts.ini"
}

# Load the top-level scalar vars of the given YAML files into VARS. Later files
# win, mirroring Ansible precedence. Only flat `key: value` lines are read; the
# mount list is handled by parse_mounts.
vars_load() {
  local f key val
  for f in "$@"; do
    [ -r "$f" ] || die "vars file is not readable: $f"
    while IFS=$'\t' read -r key val; do
      [ -n "$key" ] || continue
      VARS["$key"]="$val"
    done < <(
      awk '
        /^[A-Za-z_][A-Za-z0-9_]*:/ {
          i = index($0, ":")
          key = substr($0, 1, i - 1)
          val = substr($0, i + 1)
          sub(/^[[:space:]]+/, "", val)
          sub(/[[:space:]]+#.*$/, "", val)
          if (val ~ /^".*"$/ || val ~ /^'"'"'.*'"'"'$/) val = substr(val, 2, length(val) - 2)
          print key "\t" val
        }
      ' "$f"
    )
  done
}

load_manilov_vars() {
  vars_load \
    "$MANILOV_REPO_ROOT/roles/nixos_container/defaults/main.yml" \
    "$MANILOV_REPO_ROOT/group_vars/terra/vars.yml" \
    "$MANILOV_REPO_ROOT/group_vars/nikolaigogol/vars.yml" \
    "$MANILOV_REPO_ROOT/group_vars/manilov/vars.yml"
}

vars_expand() {
  local text="$1" pass=0 key value
  while [ "$pass" -lt 10 ]; do
    case "$text" in
      *'{{'*) : ;;
      *) break ;;
    esac
    if [ "${#VARS[@]}" -gt 0 ]; then
      for key in "${!VARS[@]}"; do
        value="${VARS[$key]}"
        text="${text//\{\{ $key \}\}/$value}"
        text="${text//\{\{$key\}\}/$value}"
      done
    fi
    pass=$((pass + 1))
  done
  case "$text" in
    *'{{'*) return 1 ;;
  esac
  printf '%s' "$text"
}

vars_get() {
  local name="$1" raw out
  raw="${VARS[$name]:-}"
  [ -n "$raw" ] || die "variable '$name' is not defined in the loaded vars files"
  if ! out="$(vars_expand "$raw")"; then
    die "cannot resolve '$name' (unresolved expression: $raw)"
  fi
  printf '%s' "$out"
}

vars_get_optional() {
  local name="$1" raw out
  raw="${VARS[$name]:-}"
  [ -n "$raw" ] || {
    printf ''
    return 0
  }
  if out="$(vars_expand "$raw")"; then
    printf '%s' "$out"
  fi
  return 0
}

# --- data helpers ------------------------------------------------------------

# Read a string field out of the marker JSON already captured in `marker_json`.
# Deliberately dependency-free (no jq): the marker is a small, machine-written
# document and the fields read here are flat string values.
marker_value() {
  local key="$1" hit=""
  hit="$(printf '%s' "${marker_json:-}" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null | head -n 1)" || true
  [ -n "$hit" ] || {
    printf ''
    return 0
  }
  printf '%s' "$hit" | sed -E 's/.*"([^"]*)"$/\1/'
}

# Emit `source<TAB>target<TAB>type` for every entry of nixos_container_mounts.
parse_mounts() {
  local file="$1"
  [ -r "$file" ] || die "cannot read mount definitions from $file"
  awk '
    function trim(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function unquote(s) { s = trim(s); gsub(/^["'"'"']/, "", s); gsub(/["'"'"']$/, "", s); return s }
    /^nixos_container_mounts:[[:space:]]*$/ { list = 1; next }
    list && /^[^[:space:]#]/ { list = 0 }
    list && /^[[:space:]]*- source:/ { src = unquote(substr($0, index($0, "source:") + 7)); next }
    list && /^[[:space:]]*target:/ { tgt = unquote(substr($0, index($0, "target:") + 7)); next }
    list && /^[[:space:]]*type:/ {
      typ = unquote(substr($0, index($0, "type:") + 5))
      print src "\t" tgt "\t" typ
      src = ""; tgt = ""; typ = ""
      next
    }
  ' "$file"
}

normalize_mac() {
  printf '%s' "$1" | tr 'A-F' 'a-f' | awk -F: '
    NF != 6 { exit 1 }
    {
      out = ""
      for (i = 1; i <= NF; i++) {
        v = $i
        if (v !~ /^[0-9a-f][0-9a-f]?$/) exit 1
        if (length(v) == 1) v = "0" v
        out = out (i > 1 ? ":" : "") v
      }
      print out
    }
  '
}

sha256_of_file() {
  local file="$1" out
  if have_cmd sha256sum; then
    out="$(sha256sum "$file")"
  elif have_cmd shasum; then
    out="$(shasum -a 256 "$file")"
  else
    die "neither sha256sum nor shasum is available"
  fi
  printf '%s' "${out%% *}"
}

sha256_of_string() {
  local out
  if have_cmd sha256sum; then
    out="$(printf '%s' "$1" | sha256sum)"
  elif have_cmd shasum; then
    out="$(printf '%s' "$1" | shasum -a 256)"
  else
    die "neither sha256sum nor shasum is available"
  fi
  printf '%s' "${out%% *}"
}

validate_cidr() {
  local cidr="$1" addr prefix octet
  local -a octets=()
  case "$cidr" in
    */*) : ;;
    *) return 1 ;;
  esac
  addr="${cidr%/*}"
  prefix="${cidr#*/}"
  case "$prefix" in
    '' | *[!0-9]*) return 1 ;;
  esac
  if [ "$prefix" -lt 1 ] || [ "$prefix" -gt 32 ]; then
    return 1
  fi
  case "$addr" in
    *[!0-9.]*) return 1 ;;
  esac
  IFS='.' read -r -a octets <<<"$addr"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [ -n "$octet" ] || return 1
    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}
