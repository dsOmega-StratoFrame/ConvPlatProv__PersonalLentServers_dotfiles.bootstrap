#!/usr/bin/env bash
# scripts/manilov/host-permit.sh — the host-owned, marker-scoped FORWARD permit
# for the @Manilov VM path.
#
# Why this exists: at one nftables hook every base chain is traversed. An
# `accept` in one base chain is not final; a `drop`, including a base-chain
# policy drop, is final; a jump cannot cross tables. The host `FORWARD` policy
# is `drop` and bridged traffic also traverses the IP forward hook. The image
# owns only drop-only tables (`inet manilov_vm`, ADR 0006 D4), so the host
# grants the scoped permit. Without it the applier exits 7
# (`host-permit-missing`) and the VM path is dead.
#
# This script writes exactly two host objects, both in the existing host
# `filter` table. The table family is selected at run time and never created:
#   - `ip filter` (IPv4; the live TOS 6 layout on @terra) when it owns a
#     `FORWARD` chain;
#   - otherwise `inet filter` (the portable layout) when it owns `FORWARD`;
#   - otherwise the script exits 7 with "no forward table".
# The two objects are:
#   - a regular chain `MANILOV_FORWARD` with the marker-scoped permit rules;
#   - one jump to it from the existing `FORWARD` base chain, placed before the
#     Docker jumps (or appended when no Docker jump exists).
#
# The permit scope is the declared datapath pair: `params.datapath.tap` is the
# VM side, paired with `params.datapath.bridge` (bridge profile) or
# `params.uplink.name` (proxyarp). `params.peer.address` and `params.peer.mac`
# narrow both directions. Pseudo-ruleset (one pair; PEER is bridge or uplink;
# <family> is ip or inet, whichever owns FORWARD):
#   table <family> filter {
#     chain MANILOV_FORWARD {
#       iifname "<tap>" oifname "<peer>" [ip saddr <peer.address>] [ether saddr <peer.mac>] accept
#       iifname "<peer>" oifname "<tap>" [ip daddr <peer.address>] [ether daddr <peer.mac>] accept
#     }
#     chain FORWARD {
#       jump MANILOV_FORWARD   # inserted before the first Docker jump
#     }
#   }
#
# It never creates the host table or the base chain, never changes a policy,
# and never touches INPUT_PROTECT, input/output, DOCKER-* or the image's
# `manilov_vm` tables (ADR 0006 §12). Default mode is read-only --check.
# --apply and --rollback are dry-run unless --apply is passed explicitly.
# No sudo: on @terra the SSH account is already uid 0.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: host-permit.sh [--host HOST] [--marker PATH] [--state-dir PATH]
                      [--check | --reconcile | --install-units | --remove-units]
                      [--apply | --rollback] [--dry-run] [--standalone]

Read-only by default. The host permit is a regular chain `MANILOV_FORWARD` in
the existing host `filter` table (`ip filter` on @terra, `inet filter` as the
portable fallback) plus one jump from the existing `FORWARD` base chain,
positioned before the Docker jumps. The scope comes only from the marker. The
selected table family is recorded in the state file and named in the logs.

Modes:
  --check          (default) read-only; exit 0 when present and matching,
                   exit 7 when missing/drifted, printing every missing object.
  --apply          create/repair the permit (dry-run unless --apply is passed).
  --rollback       delete the jump and MANILOV_FORWARD only (dry-run unless
                   --apply is passed); the rest of the ruleset must not change.
  --reconcile      timer entry point: --check, then --apply only on drift.
  --install-units  install/refresh the service + timer (dry-run unless --apply).
  --remove-units   remove the service + timer (dry-run unless --apply).

  --marker PATH    marker file (default: manilov_network_marker, else
                   /etc/manilov/marker.json)
  --state-dir PATH host state directory (default: manilov_network_state_dir,
                   else /var/lib/manilov-network)
  --dry-run        report only; never write (also disables --reconcile writes)
  --standalone     run without the repo/group_vars (used by the installed unit)
  --yes            accepted for symmetry; this script never prompts

Exit codes:
  0  success / permit present
  1  write or post-write verification failed
  3  marker absent or unreadable
  7  host permit missing, drifted, or no host `filter` table (ip/inet) owns a
     `FORWARD` chain
  8  marker schema-invalid

The marker is the only selector: hostname, DEPLOY_HOST and environment
variables are never consulted.
EOF
}

MARKER_OVERRIDE=""
STATE_DIR_OVERRIDE=""
STANDALONE=0
CHECK_EXPLICIT=0
RECONCILE=0
UNIT_MODE=""
DRY_RUN_EXPLICIT=0
APPLY_REQUESTED=0
MARKER=""
STATE_DIR=""
SERVICE="manilov-network-host-permit.service"
TIMER="manilov-network-host-permit.timer"
ON_BOOT="30s"
INTERVAL="60s"
LIB_DIR="/usr/local/lib/manilov"
TPL_SERVICE=""
TPL_TIMER=""

marker_json=""
PROFILE=""
ROLE=""
UPLINK=""
TAP=""
BRIDGE=""
PEER_IFACE=""
PEER_ADDRESS=""
PEER_MAC=""
declare -a VM_IFACES=()
declare -a RULES=()
declare -a DRIFT_CODES=()
declare -a DRIFT_DETAILS=()
OUR_JUMP_HANDLES=""
FIRST_DOCKER_HANDLE=""
DOCKER_LABEL=""
OUR_BEFORE_DOCKER=0
BACKUP_ARCHIVE=""
BACKUP_SHA=""
HOST_TABLE_FAMILY=""
HOST_TABLE=""

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check)
        CHECK_EXPLICIT=1
        shift
        ;;
      --reconcile)
        RECONCILE=1
        shift
        ;;
      --install-units)
        UNIT_MODE="install"
        shift
        ;;
      --remove-units)
        UNIT_MODE="remove"
        shift
        ;;
      --standalone)
        STANDALONE=1
        shift
        ;;
      --apply)
        APPLY_REQUESTED=1
        APPLY=1
        shift
        ;;
      --dry-run)
        DRY_RUN_EXPLICIT=1
        APPLY=0
        shift
        ;;
      --marker)
        [ "$#" -ge 2 ] || die "--marker needs a value"
        MARKER_OVERRIDE="$2"
        shift 2
        ;;
      --marker=*)
        MARKER_OVERRIDE="${1#*=}"
        shift
        ;;
      --state-dir)
        [ "$#" -ge 2 ] || die "--state-dir needs a value"
        STATE_DIR_OVERRIDE="$2"
        shift 2
        ;;
      --state-dir=*)
        STATE_DIR_OVERRIDE="${1#*=}"
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
  if [ "$DRY_RUN_EXPLICIT" -eq 1 ]; then
    APPLY=0
  fi
}

resolve_mode() {
  if [ "$CHECK_EXPLICIT" -eq 1 ]; then
    if [ "$RECONCILE" -eq 1 ] || [ -n "$UNIT_MODE" ] || [ "$ROLLBACK" -eq 1 ] || [ "$APPLY_REQUESTED" -eq 1 ]; then
      die "--check cannot be combined with --reconcile, --install-units, --remove-units, --rollback or --apply"
    fi
    printf 'check'
    return 0
  fi
  if [ "$RECONCILE" -eq 1 ]; then
    if [ -n "$UNIT_MODE" ] || [ "$ROLLBACK" -eq 1 ]; then
      die "--reconcile cannot be combined with --install-units, --remove-units or --rollback"
    fi
    printf 'reconcile'
    return 0
  fi
  if [ -n "$UNIT_MODE" ]; then
    if [ "$ROLLBACK" -eq 1 ]; then
      die "--install-units/--remove-units cannot be combined with --rollback"
    fi
    printf '%s-units' "$UNIT_MODE"
    return 0
  fi
  if [ "$ROLLBACK" -eq 1 ]; then
    printf 'rollback'
    return 0
  fi
  if [ "$APPLY_REQUESTED" -eq 1 ]; then
    printf 'apply'
    return 0
  fi
  printf 'check'
}

validate_ifname() {
  local name="$1"
  case "$name" in
    "" | *[!A-Za-z0-9_.:-]*) return 1 ;;
    . | ..) return 1 ;;
  esac
  [ "${#name}" -le 15 ] || return 1
  return 0
}

validate_unit_name() {
  local name="$1"
  case "$name" in
    "" | *[!A-Za-z0-9_.@-]*) return 1 ;;
    *.service | *.timer) return 0 ;;
  esac
  return 1
}

validate_time_span() {
  local span="$1"
  case "$span" in
    "" | *[!0-9smindwh]*) return 1 ;;
    [0-9]*) return 0 ;;
  esac
  return 1
}

die_schema() { MANILOV_EXIT=8 die "marker schema-invalid: $*"; }
die_permit() { MANILOV_EXIT=7 die "$*"; }

json_wellformed() {
  local json="$1" trimmed
  trimmed="$(printf '%s' "$json" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$trimmed" in
    \{*\}) : ;;
    *) return 1 ;;
  esac
  printf '%s' "$json" | awk '
    BEGIN { depth = 0; instr = 0; esc = 0 }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (instr) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") instr = 0
        } else {
          if (c == "\"") instr = 1
          else if (c == "{" || c == "[") depth++
          else if (c == "}" || c == "]") {
            depth--
            if (depth < 0) exit 1
          }
        }
      }
    }
    END { if (depth != 0 || instr) exit 1 }
  '
}

json_slice() {
  local json="$1" key="$2" opener="$3" closer="$4"
  printf '%s' "$json" | awk -v key="$key" -v opener="$opener" -v closer="$closer" '
    { doc = doc $0 "\n" }
    END {
      needle = "\"" key "\""
      i = index(doc, needle)
      if (i == 0) exit 0
      i += length(needle)
      while (i <= length(doc)) {
        c = substr(doc, i, 1)
        if (c == opener) break
        if (c == "," || c == "}" || c == "]") exit 0
        i++
      }
      if (i > length(doc)) exit 0
      depth = 0; instr = 0; esc = 0
      for (j = i; j <= length(doc); j++) {
        c = substr(doc, j, 1)
        if (instr) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") instr = 0
        } else {
          if (c == "\"") instr = 1
          else if (c == opener) depth++
          else if (c == closer) {
            depth--
            if (depth == 0) {
              printf "%s", substr(doc, i, j - i + 1)
              exit 0
            }
          }
        }
      }
    }
  '
}

json_object() { json_slice "$1" "$2" "{" "}"; }

json_string() {
  local json="$1" key="$2" hit
  hit="$(printf '%s' "$json" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null | head -n 1)" || true
  if [ -z "$hit" ]; then
    return 0
  fi
  printf '%s' "$hit" | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}

json_has_key() {
  local json="$1" key="$2"
  printf '%s' "$json" | grep -qE "\"${key}\"[[:space:]]*:" 2>/dev/null
}

json_object_keys() {
  local json="$1"
  printf '%s' "$json" | awk '
    BEGIN { depth = 0; instr = 0; esc = 0; inkey = 0; wantkey = 0 }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (instr || inkey) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") {
            if (inkey) { print key; inkey = 0; key = "" }
            else instr = 0
          } else if (inkey) key = key c
        } else {
          if (c == "\"") {
            if (depth == 1 && wantkey) { inkey = 1; key = ""; wantkey = 0 }
            else instr = 1
          } else if (c == "{") {
            depth++
            if (depth == 1) wantkey = 1
          } else if (c == "[") {
            depth++
          } else if (c == "}" || c == "]") {
            depth--
          } else if (c == "," && depth == 1) {
            wantkey = 1
          }
        }
      }
    }
  '
}

validate_object_keys() {
  local obj="$1" context="$2" key
  shift 2
  local -a allowed=("$@")
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! array_has "$key" "${allowed[@]}"; then
      die_schema "$context has unknown key '$key'"
    fi
  done < <(json_object_keys "$obj")
}

array_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

add_vm_iface() {
  local iface="$1"
  [ -n "$iface" ] || return 0
  validate_ifname "$iface" || die_schema "interface '$iface' from the marker is not a valid interface name"
  if [ "${#VM_IFACES[@]}" -gt 0 ] && array_has "$iface" "${VM_IFACES[@]}"; then
    return 0
  fi
  VM_IFACES+=("$iface")
}

peer_match() {
  local dir="$1" out=""
  case "$dir" in
    src)
      if [ -n "$PEER_ADDRESS" ]; then out="$out ip saddr $PEER_ADDRESS"; fi
      if [ -n "$PEER_MAC" ]; then out="$out ether saddr $PEER_MAC"; fi
      ;;
    dst)
      if [ -n "$PEER_ADDRESS" ]; then out="$out ip daddr $PEER_ADDRESS"; fi
      if [ -n "$PEER_MAC" ]; then out="$out ether daddr $PEER_MAC"; fi
      ;;
  esac
  printf '%s' "$out"
}

load_marker() {
  local schema params_json uplink_json datapath_json peer_json

  if ! host_file_exists "$MARKER"; then
    error "marker absent: $MARKER; the permit scope is marker-driven and is never inferred from hostname, DEPLOY_HOST or env"
    exit 3
  fi
  marker_json="$(host_read_file "$MARKER")"
  if [ -z "$marker_json" ]; then
    error "marker unreadable or empty: $MARKER"
    exit 3
  fi
  if ! json_wellformed "$marker_json"; then
    die_schema "not well-formed JSON: $MARKER"
  fi

  schema="$(json_string "$marker_json" schema)"
  if [ "$schema" != "manilov.network.marker/v1" ]; then
    die_schema "schema '$schema' is not 'manilov.network.marker/v1' ($MARKER)"
  fi

  PROFILE="$(json_string "$marker_json" profile)"
  case "$PROFILE" in
    proxyarp | bridge) : ;;
    *) die_schema "profile '$PROFILE' is not proxyarp|bridge" ;;
  esac

  ROLE="$(json_string "$marker_json" role)"
  case "$ROLE" in
    owner | consumer) : ;;
    *) die_schema "role '$ROLE' is not owner|consumer" ;;
  esac

  params_json="$(json_object "$marker_json" params)"
  [ -n "$params_json" ] || die_schema "missing 'params' object"
  validate_object_keys "$params_json" "params" \
    uplink management addressing datapath peer confirmDeadline

  uplink_json="$(json_object "$params_json" uplink)"
  [ -n "$uplink_json" ] || die_schema "missing params.uplink"
  validate_object_keys "$uplink_json" "params.uplink" name
  UPLINK="$(json_string "$uplink_json" name)"
  [ -n "$UPLINK" ] || die_schema "missing params.uplink.name"
  validate_ifname "$UPLINK" || die_schema "params.uplink.name '$UPLINK' is not a valid interface name"

  datapath_json="$(json_object "$params_json" datapath)"
  [ -n "$datapath_json" ] || die_schema "missing params.datapath"
  validate_object_keys "$datapath_json" "params.datapath" tap bridge
  TAP="$(json_string "$datapath_json" tap)"
  BRIDGE="$(json_string "$datapath_json" bridge)"
  [ -n "$TAP" ] || die_schema "missing params.datapath.tap"
  validate_ifname "$TAP" || die_schema "params.datapath.tap '$TAP' is not a valid interface name"
  if json_has_key "$datapath_json" bridge; then
    [ -n "$BRIDGE" ] || die_schema "params.datapath.bridge is not a string"
  fi
  if [ -n "$BRIDGE" ]; then
    validate_ifname "$BRIDGE" || die_schema "params.datapath.bridge '$BRIDGE' is not a valid interface name"
  fi

  peer_json="$(json_object "$params_json" peer)"
  PEER_ADDRESS=""
  PEER_MAC=""
  if json_has_key "$params_json" peer && [ -z "$peer_json" ]; then
    die_schema "params.peer is not an object"
  fi
  if [ -n "$peer_json" ]; then
    validate_object_keys "$peer_json" "params.peer" address mac
    PEER_ADDRESS="$(json_string "$peer_json" address)"
    PEER_MAC="$(json_string "$peer_json" mac)"
    if json_has_key "$peer_json" address; then
      [ -n "$PEER_ADDRESS" ] || die_schema "params.peer.address is not a string"
    fi
    if [ -n "$PEER_ADDRESS" ]; then
      case "$PEER_ADDRESS" in
        */*)
          validate_cidr "$PEER_ADDRESS" ||
            die_schema "params.peer.address '$PEER_ADDRESS' is not an IPv4 CIDR"
          ;;
        *)
          validate_cidr "$PEER_ADDRESS/32" ||
            die_schema "params.peer.address '$PEER_ADDRESS' is not an IPv4 address or CIDR"
          PEER_ADDRESS="$PEER_ADDRESS/32"
          ;;
      esac
    fi
    if json_has_key "$peer_json" mac; then
      [ -n "$PEER_MAC" ] || die_schema "params.peer.mac is not a string"
    fi
    if [ -n "$PEER_MAC" ]; then
      if ! PEER_MAC="$(normalize_mac "$PEER_MAC" 2>/dev/null)"; then
        die_schema "params.peer.mac is not a MAC address"
      fi
    fi
  fi

  if [ "$PROFILE" = "bridge" ]; then
    [ -n "$BRIDGE" ] || die_schema "profile 'bridge' requires params.datapath.bridge"
    PEER_IFACE="$BRIDGE"
  else
    PEER_IFACE="$UPLINK"
  fi
  if [ "$TAP" = "$UPLINK" ]; then
    die_schema "params.datapath.tap equals params.uplink.name ('$UPLINK')"
  fi
  if [ -n "$BRIDGE" ] && [ "$BRIDGE" = "$UPLINK" ]; then
    die_schema "params.datapath.bridge equals params.uplink.name ('$UPLINK')"
  fi
  if [ "$TAP" = "$PEER_IFACE" ]; then
    die_schema "params.datapath.tap equals the declared permit peer '$PEER_IFACE'"
  fi

  VM_IFACES=()
  add_vm_iface "$TAP"
  add_vm_iface "$PEER_IFACE"

  RULES=(
    "iifname \"$TAP\" oifname \"$PEER_IFACE\"$(peer_match src) accept"
    "iifname \"$PEER_IFACE\" oifname \"$TAP\"$(peer_match dst) accept"
  )

  pass_check "marker $MARKER: profile=$PROFILE role=$ROLE uplink=$UPLINK peer=$PEER_IFACE tap=$TAP"
  info "permit scope: ${#VM_IFACES[@]} interface(s), ${#RULES[@]} rule(s)${PEER_ADDRESS:+; peer address $PEER_ADDRESS}${PEER_MAC:+; peer MAC $PEER_MAC}"
}

select_forward_table() {
  local family
  HOST_TABLE_FAMILY=""
  HOST_TABLE=""
  for family in ip inet; do
    if host_cmd "nft list chain $family filter FORWARD >/dev/null 2>&1"; then
      HOST_TABLE_FAMILY="$family"
      HOST_TABLE="$family filter"
      info "host table: $HOST_TABLE (selected: family=$family, FORWARD chain present)"
      return 0
    fi
  done
  return 1
}

select_rollback_table() {
  local family
  if select_forward_table; then
    return 0
  fi
  for family in ip inet; do
    if host_cmd "nft list table $family filter >/dev/null 2>&1"; then
      HOST_TABLE_FAMILY="$family"
      HOST_TABLE="$family filter"
      info "host table: $HOST_TABLE (selected for rollback: family=$family, no FORWARD chain)"
      return 0
    fi
  done
  return 1
}

nft_chain_exists() { host_cmd "nft list chain $HOST_TABLE '$1' >/dev/null 2>&1"; }
nft_list_chain() { host_cmd "nft list chain $HOST_TABLE '$1' 2>/dev/null"; }

chain_rule_lines() {
  sed -e 's/[[:space:]]*# handle [0-9][0-9]*$//' |
    sed -n '/^[[:space:]]*chain[[:space:]]\+MANILOV_FORWARD[[:space:]]*{/,/^[[:space:]]*}/p' |
    sed -e '1d' -e '$d'
}

normalize_rule_lines() {
  sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' -e 's/"//g'
}

strip_managed_ruleset() {
  awk '
    /^[[:space:]]*chain[[:space:]]+MANILOV_FORWARD[[:space:]]*\{/ { skip = 1; next }
    skip {
      if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) skip = 0
      next
    }
    /^[[:space:]]*jump[[:space:]]+MANILOV_FORWARD([[:space:]]|$)/ { next }
    { print }
  '
}

inspect_forward() {
  local out kind handle text
  out="$(host_cmd "nft -a list chain $HOST_TABLE FORWARD 2>/dev/null")" || true
  OUR_JUMP_HANDLES=""
  FIRST_DOCKER_HANDLE=""
  DOCKER_LABEL=""
  OUR_BEFORE_DOCKER=0
  while IFS=$'\t' read -r kind handle text; do
    [ -n "$kind" ] || continue
    case "$kind" in
      ours)
        OUR_JUMP_HANDLES="$OUR_JUMP_HANDLES $handle"
        if [ -z "$FIRST_DOCKER_HANDLE" ]; then
          OUR_BEFORE_DOCKER=1
        fi
        ;;
      docker)
        if [ -z "$FIRST_DOCKER_HANDLE" ]; then
          FIRST_DOCKER_HANDLE="$handle"
          DOCKER_LABEL="$text"
        fi
        ;;
    esac
    if [ "$kind" = "ours" ] && [ -n "$FIRST_DOCKER_HANDLE" ]; then
      OUR_BEFORE_DOCKER=0
    fi
  done < <(
    printf '%s\n' "$out" | awk '
      /# handle [0-9]+/ {
        line = $0
        h = line
        sub(/.*# handle /, "", h)
        sub(/[^0-9].*/, "", h)
        k = "other"
        if (line ~ /jump[[:space:]]+MANILOV_FORWARD/) k = "ours"
        else if (line ~ /(jump|goto)[[:space:]]+DOCKER-/) k = "docker"
        if (k != "other") {
          t = line
          sub(/^[[:space:]]*/, "", t)
          sub(/[[:space:]]*# handle.*/, "", t)
          printf "%s\t%s\t%s\n", k, h, t
        }
      }
    '
  )
  OUR_JUMP_HANDLES="${OUR_JUMP_HANDLES# }"
}

report_drift() {
  local code="$1" detail="$2"
  DRIFT_CODES+=("$code")
  DRIFT_DETAILS+=("$detail")
  printf '[manilov:%s] DRIFT code=%s detail=%s\n' "$SCRIPT_NAME" "$code" "$detail" >&2
}

write_rule_file() {
  local file="$1" text="$2"
  : >"$file"
  if [ -n "$text" ]; then
    printf '%s\n' "$text" | sed '/^$/d' >"$file"
  fi
}

check_permit() {
  local actual expected line missing extra chain_text count
  local expected_file="$WORK/host-permit.expected"
  local actual_file="$WORK/host-permit.actual"
  DRIFT_CODES=()
  DRIFT_DETAILS=()

  if ! select_forward_table; then
    report_drift "host-forward-table-missing" "no forward table: neither 'ip filter' nor 'inet filter' has a FORWARD chain; the script never creates a table or a base chain (that is a policy change)"
    return 7
  fi
  if ! nft_chain_exists FORWARD; then
    report_drift "host-forward-missing" "base chain $HOST_TABLE FORWARD is absent; the script never creates a base chain (that is a policy change)"
    return 7
  fi

  if ! nft_chain_exists MANILOV_FORWARD; then
    report_drift "chain-missing" "regular chain $HOST_TABLE MANILOV_FORWARD is absent"
  else
    chain_text="$(nft_list_chain MANILOV_FORWARD || true)"
    if printf '%s\n' "$chain_text" | grep -qE '^[[:space:]]*type[[:space:]]'; then
      report_drift "chain-not-regular" "$HOST_TABLE MANILOV_FORWARD is a base chain, not the expected regular chain"
    else
      actual="$(printf '%s\n' "$chain_text" | chain_rule_lines | normalize_rule_lines)"
      expected="$(printf '%s\n' "${RULES[@]}" | normalize_rule_lines)"
      write_rule_file "$expected_file" "$expected"
      write_rule_file "$actual_file" "$actual"
      if ! diff -q "$expected_file" "$actual_file" >/dev/null 2>&1; then
        missing="$(comm -23 <(sort "$expected_file") <(sort "$actual_file") || true)"
        extra="$(comm -13 <(sort "$expected_file") <(sort "$actual_file") || true)"
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          report_drift "rule-missing" "MANILOV_FORWARD lacks: $line"
        done <<<"$missing"
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          report_drift "rule-unexpected" "MANILOV_FORWARD has an unmanaged rule: $line"
        done <<<"$extra"
        if [ -z "$missing" ] && [ -z "$extra" ]; then
          report_drift "rule-order" "MANILOV_FORWARD has the right rules in the wrong order"
        fi
      fi
    fi
  fi

  inspect_forward
  if [ -z "$OUR_JUMP_HANDLES" ]; then
    report_drift "jump-missing" "$HOST_TABLE FORWARD has no jump to MANILOV_FORWARD"
  else
    count="$(printf '%s\n' "$OUR_JUMP_HANDLES" | wc -w | tr -d ' ')"
    if [ "$count" -gt 1 ]; then
      report_drift "jump-duplicate" "$HOST_TABLE FORWARD has $count jumps to MANILOV_FORWARD"
    fi
    if [ -n "$FIRST_DOCKER_HANDLE" ] && [ "$OUR_BEFORE_DOCKER" -ne 1 ]; then
      report_drift "jump-misplaced" "the MANILOV_FORWARD jump must precede the first Docker jump ($DOCKER_LABEL)"
    fi
  fi

  if [ "${#DRIFT_CODES[@]}" -gt 0 ]; then
    return 7
  fi
  return 0
}

backup_ruleset() {
  local dir="$STATE_DIR/host-permit" ts archive
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$dir/ruleset.$ts.nft"
  host_cmd "mkdir -p '$dir'" || die "cannot create $dir on the host"
  host_cmd "nft list ruleset > '$archive'" || die "cannot archive the ruleset to $archive"
  BACKUP_SHA="$(host_cmd "sha256sum '$archive' | cut -d' ' -f1")" || die "cannot hash $archive"
  host_cmd "printf '%s  %s\n' '$BACKUP_SHA' '$(basename "$archive")' > '$archive.sha256'" ||
    die "cannot write the hash record $archive.sha256"
  BACKUP_ARCHIVE="$archive"
  ok "ruleset archive: $archive (sha256 $BACKUP_SHA)"
}

reposition_jump() {
  local handle count=0
  inspect_forward
  if [ -n "$OUR_JUMP_HANDLES" ]; then
    count="$(printf '%s\n' "$OUR_JUMP_HANDLES" | wc -w | tr -d ' ')"
  fi
  if [ "$count" -eq 1 ] && { [ -z "$FIRST_DOCKER_HANDLE" ] || [ "$OUR_BEFORE_DOCKER" -eq 1 ]; }; then
    ok "the jump is already present in the correct position"
    return 0
  fi
  if [ "$count" -gt 0 ]; then
    local -a handles=()
    read -r -a handles <<<"$OUR_JUMP_HANDLES"
    for handle in "${handles[@]}"; do
      host_cmd "nft delete rule $HOST_TABLE FORWARD handle '$handle'" ||
        die "cannot remove the existing MANILOV_FORWARD jump (handle $handle)"
    done
    ok "removed $count existing jump(s) to MANILOV_FORWARD"
  fi
  if [ -n "$FIRST_DOCKER_HANDLE" ]; then
    host_cmd "nft insert rule $HOST_TABLE FORWARD handle '$FIRST_DOCKER_HANDLE' jump MANILOV_FORWARD comment \"manilov-host-permit\"" ||
      die "cannot insert the MANILOV_FORWARD jump before $DOCKER_LABEL"
    ok "inserted the jump before $DOCKER_LABEL ($HOST_TABLE FORWARD)"
  else
    host_cmd "nft add rule $HOST_TABLE FORWARD jump MANILOV_FORWARD comment \"manilov-host-permit\"" ||
      die "cannot append the MANILOV_FORWARD jump"
    warn "no Docker jump in $HOST_TABLE FORWARD; appended the MANILOV_FORWARD jump at the end"
  fi
}

write_state() {
  local dir="$STATE_DIR/host-permit" ts rules_sha marker_sha interfaces
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s\n' "${RULES[@]}" >"$WORK/host-permit.rules"
  rules_sha="$(sha256_of_file "$WORK/host-permit.rules")"
  marker_sha="$(sha256_of_string "$marker_json")"
  interfaces="$(printf '%s ' "${VM_IFACES[@]}")"
  interfaces="${interfaces% }"
  if ! host_sh <<EOF
set -eu
mkdir -p '$dir'
cat > '$dir/host-permit.state' <<'STATE'
timestamp=$ts
marker=$MARKER
marker_sha256=$marker_sha
table=$HOST_TABLE
table_family=$HOST_TABLE_FAMILY
profile=$PROFILE
role=$ROLE
uplink=$UPLINK
interfaces=$interfaces
rules_sha256=$rules_sha
ruleset_archive=$BACKUP_ARCHIVE
ruleset_archive_sha256=$BACKUP_SHA
STATE
EOF
  then
    die "cannot record $dir/host-permit.state"
  fi
  ok "recorded $dir/host-permit.state (table=$HOST_TABLE family=$HOST_TABLE_FAMILY)"
}

apply_permit() {
  local before after rule rc=0
  local batch="$WORK/host-permit.chain.nft"

  if ! select_forward_table; then
    die_permit "no forward table: neither 'ip filter' nor 'inet filter' has a FORWARD chain; refusing to create a table or base chain (that is a policy change, not a permit)"
  fi
  if nft_chain_exists MANILOV_FORWARD; then
    if nft_list_chain MANILOV_FORWARD | grep -qE '^[[:space:]]*type[[:space:]]'; then
      die_permit "$HOST_TABLE MANILOV_FORWARD exists but is a base chain; refusing to modify it"
    fi
  fi

  step "plan"
  info "host table:   $HOST_TABLE (family=$HOST_TABLE_FAMILY; existing, never created by this script)"
  info "permit chain: MANILOV_FORWARD (regular; scoped to the marker)"
  for rule in "${RULES[@]}"; do
    plan "add rule $HOST_TABLE MANILOV_FORWARD $rule"
  done
  inspect_forward
  if [ -n "$OUR_JUMP_HANDLES" ]; then
    plan "remove the existing MANILOV_FORWARD jump(s) and re-insert once"
  fi
  if [ -n "$FIRST_DOCKER_HANDLE" ]; then
    plan "insert jump $HOST_TABLE FORWARD before handle $FIRST_DOCKER_HANDLE ($DOCKER_LABEL)"
  else
    plan "append jump $HOST_TABLE FORWARD (no Docker jump present)"
  fi
  plan "archive the current ruleset under $STATE_DIR/host-permit before writing"
  info "pseudo-ruleset (selected table $HOST_TABLE):"
  info "  table $HOST_TABLE {"
  info "    chain MANILOV_FORWARD {"
  for rule in "${RULES[@]}"; do
    info "      $rule"
  done
  info "    }"
  info "    chain FORWARD {"
  if [ -n "$FIRST_DOCKER_HANDLE" ]; then
    info "      jump MANILOV_FORWARD   # before $DOCKER_LABEL (handle $FIRST_DOCKER_HANDLE)"
  else
    info "      jump MANILOV_FORWARD   # appended; no Docker jump present"
  fi
  info "    }"
  info "  }"

  require_apply

  step "backup"
  backup_ruleset

  before="$(host_cmd "nft list ruleset")" || die "cannot read the ruleset before the write"

  step "write"
  {
    if nft_chain_exists MANILOV_FORWARD; then
      printf 'flush chain %s MANILOV_FORWARD\n' "$HOST_TABLE"
    else
      printf 'add chain %s MANILOV_FORWARD\n' "$HOST_TABLE"
    fi
    for rule in "${RULES[@]}"; do
      printf 'add rule %s MANILOV_FORWARD %s\n' "$HOST_TABLE" "$rule"
    done
  } >"$batch"
  if ! host_sh <<EOF
set -eu
nft -f - <<'NFT'
$(cat "$batch")
NFT
EOF
  then
    die "nft rejected the MANILOV_FORWARD batch in $HOST_TABLE"
  fi
  ok "wrote chain $HOST_TABLE MANILOV_FORWARD (${#RULES[@]} rule(s))"

  step "jump"
  reposition_jump

  step "verify"
  after="$(host_cmd "nft list ruleset")" || die "cannot read the ruleset after the write"
  if ! diff -u <(printf '%s\n' "$before" | strip_managed_ruleset) <(printf '%s\n' "$after" | strip_managed_ruleset) >"$WORK/host-permit.ruleset.diff"; then
    sed 's/^/    /' "$WORK/host-permit.ruleset.diff" >&2
    die "the write changed host objects outside MANILOV_FORWARD and its jump; inspect $WORK/host-permit.ruleset.diff"
  fi
  pass_check "only $HOST_TABLE MANILOV_FORWARD and its jump changed"

  if check_permit; then
    pass_check "the chain and jump match the marker-derived rules"
  else
    rc=$?
    die "the permit did not converge after apply (exit $rc); the DRIFT lines above list what is still wrong"
  fi

  write_state
  ok "host permit applied in $HOST_TABLE"
}

rollback_permit() {
  local before after count=0 handle
  step "plan"
  if ! select_rollback_table; then
    ok "no host 'filter' table (ip or inet) is present; nothing to roll back"
    exit 0
  fi
  info "rollback table: $HOST_TABLE (family=$HOST_TABLE_FAMILY)"
  OUR_JUMP_HANDLES=""
  if nft_chain_exists FORWARD; then
    inspect_forward
  fi
  if [ -n "$OUR_JUMP_HANDLES" ]; then
    count="$(printf '%s\n' "$OUR_JUMP_HANDLES" | wc -w | tr -d ' ')"
    plan "delete $count jump(s) to MANILOV_FORWARD from $HOST_TABLE FORWARD"
  else
    info "no jump to MANILOV_FORWARD in $HOST_TABLE FORWARD"
  fi
  if nft_chain_exists MANILOV_FORWARD; then
    plan "delete chain $HOST_TABLE MANILOV_FORWARD"
  else
    info "no chain $HOST_TABLE MANILOV_FORWARD"
  fi
  if [ "$count" -eq 0 ] && ! nft_chain_exists MANILOV_FORWARD; then
    ok "nothing to roll back"
    exit 0
  fi

  require_apply

  step "rollback"
  before="$(host_cmd "nft list ruleset")" || die "cannot read the ruleset before the rollback"
  if [ "$count" -gt 0 ]; then
    local -a handles=()
    read -r -a handles <<<"$OUR_JUMP_HANDLES"
    for handle in "${handles[@]}"; do
      host_cmd "nft delete rule $HOST_TABLE FORWARD handle '$handle'" ||
        die "cannot delete the MANILOV_FORWARD jump (handle $handle)"
    done
  fi
  if nft_chain_exists MANILOV_FORWARD; then
    host_cmd "nft delete chain $HOST_TABLE MANILOV_FORWARD" ||
      die "cannot delete chain $HOST_TABLE MANILOV_FORWARD"
  fi
  after="$(host_cmd "nft list ruleset")" || die "cannot read the ruleset after the rollback"
  if ! diff -u <(printf '%s\n' "$before" | strip_managed_ruleset) <(printf '%s\n' "$after" | strip_managed_ruleset) >"$WORK/host-permit.rollback.diff"; then
    sed 's/^/    /' "$WORK/host-permit.rollback.diff" >&2
    die "the rollback changed host objects outside MANILOV_FORWARD and its jump"
  fi
  pass_check "the jump and MANILOV_FORWARD were removed; the rest of the ruleset is unchanged"
  ok "host permit rolled back from $HOST_TABLE"
}

resolve_config() {
  local v
  if [ "$STANDALONE" -eq 1 ]; then
    MARKER="$MANILOV_DEFAULT_MARKER"
    STATE_DIR="$MANILOV_DEFAULT_STATE_DIR"
  else
    require_repo_layout
    load_manilov_vars
    MARKER="$(vars_get_optional manilov_network_marker)"
    STATE_DIR="$(vars_get_optional manilov_network_state_dir)"
    [ -n "$MARKER" ] || MARKER="$MANILOV_DEFAULT_MARKER"
    [ -n "$STATE_DIR" ] || STATE_DIR="$MANILOV_DEFAULT_STATE_DIR"
    v="$(vars_get_optional manilov_host_permit_service)"
    [ -n "$v" ] || v="manilov-network-host-permit.service"
    SERVICE="$v"
    v="$(vars_get_optional manilov_host_permit_timer)"
    [ -n "$v" ] || v="manilov-network-host-permit.timer"
    TIMER="$v"
    v="$(vars_get_optional manilov_host_permit_on_boot)"
    [ -n "$v" ] || v="30s"
    ON_BOOT="$v"
    v="$(vars_get_optional manilov_host_permit_interval)"
    [ -n "$v" ] || v="60s"
    INTERVAL="$v"
    v="$(vars_get_optional manilov_host_permit_lib_dir)"
    [ -n "$v" ] || v="/usr/local/lib/manilov"
    LIB_DIR="$v"
  fi
  if [ -n "$MARKER_OVERRIDE" ]; then MARKER="$MARKER_OVERRIDE"; fi
  if [ -n "$STATE_DIR_OVERRIDE" ]; then STATE_DIR="$STATE_DIR_OVERRIDE"; fi
  require_safe_value "$MARKER" "marker path"
  require_safe_value "$STATE_DIR" "state directory"
  require_safe_value "$LIB_DIR" "unit install directory"
  validate_unit_name "$SERVICE" || die "unit name '$SERVICE' is not a *.service name"
  validate_unit_name "$TIMER" || die "unit name '$TIMER' is not a *.timer name"
  validate_time_span "$ON_BOOT" || die "on-boot span '$ON_BOOT' is not a systemd time span (e.g. 30s)"
  validate_time_span "$INTERVAL" || die "interval '$INTERVAL' is not a systemd time span (e.g. 60s)"
  TPL_SERVICE="$MANILOV_SCRIPTS_DIR/templates/manilov-network-host-permit.service.in"
  TPL_TIMER="$MANILOV_SCRIPTS_DIR/templates/manilov-network-host-permit.timer.in"
}

install_file_atomic() {
  local local_file="$1" remote="$2" mode="$3" ts="$4" current_sha wanted_sha tmp
  wanted_sha="$(sha256_of_file "$local_file")"
  current_sha="$(host_cmd "sha256sum '$remote' 2>/dev/null | cut -d' ' -f1" || true)"
  if [ "$current_sha" = "$wanted_sha" ]; then
    info "$remote is up to date"
    return 0
  fi
  if host_file_exists "$remote"; then
    host_cmd "cp -a '$remote' '$STATE_DIR/host-permit/units.$ts/$(basename "$remote")'" ||
      die "cannot back up $remote"
  fi
  tmp="$remote.tmp.$ts"
  host_write_file "$tmp" <"$local_file" || die "cannot write $tmp on the host"
  host_cmd "chmod '$mode' '$tmp' && mv -f '$tmp' '$remote'" || die "cannot install $remote"
  ok "installed $remote"
}

install_units() {
  local ts execstart
  [ -f "$TPL_SERVICE" ] || die "missing template $TPL_SERVICE"
  [ -f "$TPL_TIMER" ] || die "missing template $TPL_TIMER"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  execstart="$LIB_DIR/host-permit.sh"
  require_safe_value "$execstart" "installed script path"
  sed -e "s|@@EXECSTART@@|$execstart|g" -e "s|@@MARKER@@|$MARKER|g" -e "s|@@STATE_DIR@@|$STATE_DIR|g" "$TPL_SERVICE" >"$WORK/$SERVICE"
  sed -e "s|@@SERVICE@@|$SERVICE|g" -e "s|@@ON_BOOT@@|$ON_BOOT|g" -e "s|@@INTERVAL@@|$INTERVAL|g" "$TPL_TIMER" >"$WORK/$TIMER"

  step "units"
  info "planned /etc/systemd/system/$SERVICE:"
  sed 's/^/    /' "$WORK/$SERVICE" >&2
  info "planned /etc/systemd/system/$TIMER:"
  sed 's/^/    /' "$WORK/$TIMER" >&2

  plan "install $LIB_DIR/lib.sh, $LIB_DIR/host-permit.sh and the unit templates (sha-idempotent, mode 0644/0755)"
  plan "install /etc/systemd/system/$SERVICE and /etc/systemd/system/$TIMER (backup first, mode 0644)"
  plan "systemctl daemon-reload"
  plan "systemctl enable --now $TIMER"
  plan "systemctl start $SERVICE (immediate --reconcile)"

  require_apply

  host_cmd "mkdir -p '$LIB_DIR' '$LIB_DIR/templates' /etc/systemd/system '$STATE_DIR/host-permit/units.$ts'" ||
    die "cannot create the install directories"
  install_file_atomic "$MANILOV_SCRIPTS_DIR/lib.sh" "$LIB_DIR/lib.sh" 0644 "$ts"
  install_file_atomic "$MANILOV_SCRIPTS_DIR/host-permit.sh" "$LIB_DIR/host-permit.sh" 0755 "$ts"
  install_file_atomic "$TPL_SERVICE" "$LIB_DIR/templates/manilov-network-host-permit.service.in" 0644 "$ts"
  install_file_atomic "$TPL_TIMER" "$LIB_DIR/templates/manilov-network-host-permit.timer.in" 0644 "$ts"
  install_file_atomic "$WORK/$SERVICE" "/etc/systemd/system/$SERVICE" 0644 "$ts"
  install_file_atomic "$WORK/$TIMER" "/etc/systemd/system/$TIMER" 0644 "$ts"

  host_cmd "systemctl daemon-reload" || die "systemctl daemon-reload failed"
  host_cmd "systemctl enable --now '$TIMER'" || die "cannot enable/start $TIMER"
  if host_cmd "systemctl start '$SERVICE'"; then
    pass_check "$SERVICE ran --reconcile"
  else
    fail_check "$SERVICE failed to start; the timer will retry (inspect 'systemctl status $SERVICE')"
  fi
  if [ "$(host_cmd "systemctl is-enabled '$TIMER' 2>/dev/null || true")" = "enabled" ]; then
    pass_check "$TIMER is enabled"
  else
    fail_check "$TIMER is not enabled"
  fi
  if [ "$(host_cmd "systemctl is-active '$TIMER' 2>/dev/null || true")" = "active" ]; then
    pass_check "$TIMER is active"
  else
    fail_check "$TIMER is not active"
  fi
  finish_checks
}

remove_units() {
  step "units"
  plan "systemctl disable --now $TIMER"
  plan "systemctl stop $SERVICE"
  plan "rm -f /etc/systemd/system/$TIMER /etc/systemd/system/$SERVICE"
  plan "systemctl daemon-reload"
  plan "leave $LIB_DIR/lib.sh and $LIB_DIR/host-permit.sh in place (re-install is idempotent)"

  require_apply

  host_cmd "systemctl disable --now '$TIMER' >/dev/null 2>&1 || true"
  host_cmd "systemctl stop '$SERVICE' >/dev/null 2>&1 || true"
  host_cmd "rm -f '/etc/systemd/system/$TIMER' '/etc/systemd/system/$SERVICE'" ||
    die "cannot remove the permit units"
  host_cmd "systemctl daemon-reload" || die "systemctl daemon-reload failed"
  if [ "$(host_cmd "systemctl is-enabled '$TIMER' 2>/dev/null || true")" = "enabled" ]; then
    fail_check "$TIMER is still enabled"
  else
    pass_check "$TIMER is not enabled"
  fi
  ok "removed the host-permit service and timer"
  finish_checks
}

parse_script_args "$@"
MODE="$(resolve_mode)"
make_workdir

step "inputs"
resolve_config
info "host:      $MANILOV_HOST"
info "marker:    $MARKER"
info "state dir: $STATE_DIR"
info "mode:      $MODE$(if [ "$MODE" != "apply" ] && is_apply; then printf ' + apply'; elif [ "$MODE" = "apply" ] && [ "$DRY_RUN_EXPLICIT" -eq 1 ]; then printf ' (dry-run)'; fi)"
info "units:     $SERVICE / $TIMER (on-boot $ON_BOOT, interval $INTERVAL)"

step "host access"
require_host
require_host_uid0
for tool in nft sha256sum; do
  if [ "$(host_cmd "command -v $tool >/dev/null 2>&1 && printf yes || printf no")" = "yes" ]; then
    pass_check "host $tool present"
  else
    fail_check "host $tool is missing; the host permit needs it"
  fi
done
finish_checks

case "$MODE" in
  check)
    load_marker
    step "check"
    if check_permit; then
      ok "host permit present in $HOST_TABLE: MANILOV_FORWARD + jump + ${#RULES[@]} marker-scoped rule(s)"
      exit 0
    else
      rc=$?
      error "host permit is missing or drifted (exit $rc); repair with 'make -f Makefile.Manilov host-permit ARGS=--apply'"
      exit "$rc"
    fi
    ;;
  apply)
    load_marker
    apply_permit
    ;;
  reconcile)
    load_marker
    step "reconcile"
    rc=0
    if check_permit; then
      ok "host permit present; nothing to reconcile"
      exit 0
    else
      rc=$?
    fi
    if [ "$rc" -ne 7 ]; then
      exit "$rc"
    fi
    if [ "$DRY_RUN_EXPLICIT" -eq 1 ]; then
      info "dry-run: drift reported only; re-run without --dry-run to reconcile"
      exit 7
    fi
    info "reconciling the drift reported above"
    # shellcheck disable=SC2034  # read by is_apply/require_apply in lib.sh
    APPLY=1
    apply_permit
    ;;
  rollback)
    rollback_permit
    ;;
  install-units)
    install_units
    ;;
  remove-units)
    remove_units
    ;;
  *)
    die "internal error: unknown mode '$MODE'"
    ;;
esac


