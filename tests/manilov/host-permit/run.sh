#!/usr/bin/env bash
# Hermetic regression harness for scripts/manilov/host-permit.sh.
#
# The production script is exercised against a stateful fake `nft` and a fake
# `id`, entirely inside `mktemp -d`.  It never needs root, a real nft, a network
# or any host state.  Each case starts from a committed fixture under
# fixtures/nft/<scenario>.json; the fake nft mutates a copy of that file.
#
#   bash tests/manilov/host-permit/run.sh
#   KEEP=1 bash tests/manilov/host-permit/run.sh   # keep the sandbox for debug
#
# Exit status is 0 only when every check passes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
SCRIPT="$REPO/scripts/manilov/host-permit.sh"
FIXTURES="$ROOT/fixtures"
PROXYARP_MARKER="$FIXTURES/markers/proxyarp.json"
ADDRESS_ONLY_MARKER="$FIXTURES/markers/proxyarp-address-only.json"
BRIDGE_MARKER="$FIXTURES/markers/bridge.json"
UNKNOWN_MARKER="$FIXTURES/markers/unknown-key.json"
PYTHON="${PYTHON:-python3}"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/manilov-host-permit.XXXXXX")"
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    printf 'kept sandbox: %s\n' "$SANDBOX" >&2
  else
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT

export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
export PATH="$ROOT/fake-bin:$PATH"

CASE=""
STATE_DIR=""
pass=0
fail=0
rows=()

record_pass() {
  local label="$1" result="$2"
  printf 'PASS  %-56s %s\n' "$label" "$result"
  pass=$((pass + 1))
  rows+=("PASS|$label|$result")
}

record_fail() {
  local label="$1" result="$2"
  printf 'FAIL  %-56s %s\n' "$label" "$result"
  fail=$((fail + 1))
  rows+=("FAIL|$label|$result")
}

check_rc() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    record_pass "$label" "rc=$got"
  else
    record_fail "$label" "got=$got want=$want"
  fi
}

check_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    record_pass "$label" "$got"
  else
    record_fail "$label" "got='$got' want='$want'"
  fi
}

check_grep() {
  local label="$1" file="$2" pattern="$3"
  if grep -Fq -- "$pattern" "$file" 2>/dev/null; then
    record_pass "$label" "matched: $pattern"
  else
    record_fail "$label" "missing: $pattern"
  fi
}

check_not_grep() {
  local label="$1" file="$2" pattern="$3"
  if grep -Fq -- "$pattern" "$file" 2>/dev/null; then
    record_fail "$label" "unexpected: $pattern"
  else
    record_pass "$label" "absent: $pattern"
  fi
}

check_file_absent() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then
    record_pass "$label" "absent"
  else
    record_fail "$label" "exists: $path"
  fi
}

check_file_eq() {
  local label="$1" left="$2" right="$3"
  if cmp -s "$left" "$right"; then
    record_pass "$label" "byte-identical"
  else
    record_fail "$label" "differs"
    diff -u "$left" "$right" | sed 's/^/    /' >&2
  fi
}

check_state() {
  local label="$1" key="$2" value="$3"
  local file="$STATE_DIR/host-permit/host-permit.state"
  if [ -f "$file" ] && grep -Fxq -- "$key=$value" "$file"; then
    record_pass "$label" "$key=$value"
  else
    record_fail "$label" "missing $key=$value"
  fi
}

# Create a fresh case directory from a committed nft fixture.  The fixture is
# copied, never edited, so repeated runs are independent.
new_case() {
  local name="$1" scenario="$2"
  CASE="$SANDBOX/$name"
  rm -rf "$CASE"
  mkdir -p "$CASE"
  cp "$FIXTURES/nft/$scenario.json" "$CASE/nft.json"
  export FAKE_NFT_STATE="$CASE/nft.json"
  STATE_DIR="$CASE/state"
}

run_here() {
  local logname="$1" marker="$2"
  shift 2
  # Copy the marker into the sandbox: require_safe_value deliberately rejects
  # paths with characters such as '%', which a checkout path may contain.
  cp "$marker" "$CASE/marker.json"
  bash "$SCRIPT" --standalone --host local --marker "$CASE/marker.json" \
    --state-dir "$STATE_DIR" "$@" >"$CASE/$logname.log" 2>&1
}

jump_handles() {
  local table="$1"
  "$PYTHON" - "$FAKE_NFT_STATE" "$table" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
rules = state["tables"][sys.argv[2]]["chains"]["FORWARD"]["rules"]
print(" ".join(str(rule["handle"]) for rule in rules
               if rule["text"].startswith("jump MANILOV_FORWARD")))
PY
}

# Assert that the jump is the first FORWARD rule and precedes every Docker
# jump/goto.  Optionally name the Docker target that must follow it.
check_forward_order() {
  local label="$1" table="$2" docker_target="${3:-}"
  if "$PYTHON" - "$FAKE_NFT_STATE" "$table" "$docker_target" <<'PY'
import json
import re
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
table = sys.argv[2]
target = sys.argv[3]
rules = [rule["text"] for rule in state["tables"][table]["chains"]["FORWARD"]["rules"]]
ours = [i for i, text in enumerate(rules) if text.startswith("jump MANILOV_FORWARD")]
docker = [i for i, text in enumerate(rules) if re.match(r"(jump|goto) DOCKER-", text)]
ok = len(ours) == 1 and ours[0] == 0 and docker and ours[0] < docker[0]
if target:
    ok = ok and any(
        i > ours[0] and re.match(r"(jump|goto) %s(?:\s|$)" % re.escape(target), text)
        for i, text in enumerate(rules)
    )
if not ok:
    print("FORWARD rules:", json.dumps(rules, indent=2), file=sys.stderr)
    sys.exit(1)
PY
  then
    record_pass "$label" "ours first, before Docker"
  else
    record_fail "$label" "bad FORWARD order"
  fi
}

# Assert the managed chain is exactly the declared pair, in order, with no
# extra rules.  Expected rules are passed as arguments.
check_rules_exact() {
  local label="$1" table="$2"
  shift 2
  local expected="$CASE/rules.expected"
  printf '%s\n' "$@" >"$expected"
  if "$PYTHON" - "$FAKE_NFT_STATE" "$table" "$expected" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
table = sys.argv[2]
expected = [line for line in open(sys.argv[3], encoding="utf-8").read().splitlines() if line]
try:
    chain = state["tables"][table]["chains"]["MANILOV_FORWARD"]
except KeyError:
    print("MANILOV_FORWARD or table %s is missing" % table, file=sys.stderr)
    sys.exit(1)
actual = [rule["text"] for rule in chain.get("rules", [])]
if actual != expected:
    print("actual:", json.dumps(actual, indent=2), file=sys.stderr)
    print("expected:", json.dumps(expected, indent=2), file=sys.stderr)
    sys.exit(1)
PY
  then
    record_pass "$label" "exact pair, ${#} rule(s)"
  else
    record_fail "$label" "rules differ"
  fi
}

# Assert Docker chains were not rewritten by an apply.
check_docker_chains_untouched() {
  local label="$1" table="$2"
  if "$PYTHON" - "$FAKE_NFT_STATE" "$table" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
chains = state["tables"][sys.argv[2]]["chains"]
if chains["DOCKER-USER"]["rules"] != []:
    print("DOCKER-USER changed:", chains["DOCKER-USER"]["rules"], file=sys.stderr)
    sys.exit(1)
expected = ["iifname != docker0 return", "iifname docker0 jump DOCKER-BRIDGE"]
actual = [rule["text"] for rule in chains["DOCKER-FORWARD"]["rules"]]
if actual != expected:
    print("DOCKER-FORWARD changed:", actual, file=sys.stderr)
    sys.exit(1)
PY
  then
    record_pass "$label" "Docker chains unchanged"
  else
    record_fail "$label" "Docker chains changed"
  fi
}

printf '=== 1. no host filter table with FORWARD: check and apply exit 7 ===\n'
new_case noforward noforward
run_here noforward_check "$PROXYARP_MARKER" --check
check_rc "noforward/check" 7 $?
check_grep "noforward/check drift" "$CASE/noforward_check.log" "host-forward-table-missing"
run_here noforward_apply "$PROXYARP_MARKER" --apply
check_rc "noforward/apply" 7 $?
check_file_absent "noforward/apply wrote no state" "$STATE_DIR/host-permit/host-permit.state"

new_case missing missing
run_here missing_check "$PROXYARP_MARKER" --check
check_rc "missing/check" 7 $?
check_grep "missing/check drift" "$CASE/missing_check.log" "host-forward-table-missing"
run_here missing_apply "$PROXYARP_MARKER" --apply
check_rc "missing/apply" 7 $?
check_file_absent "missing/apply wrote no state" "$STATE_DIR/host-permit/host-permit.state"

printf '\n=== 2. ip filter + FORWARD: select, apply, idempotency, rollback ===\n'
new_case ip ip
nft list ruleset >"$CASE/before.nft"
nft -j list ruleset >"$CASE/before.json"
check_rc "ip/baseline snapshot" 0 $?
run_here ip_check_before "$PROXYARP_MARKER" --check
check_rc "ip/check before" 7 $?
run_here ip_apply "$PROXYARP_MARKER" --apply
check_rc "ip/apply" 0 $?
check_grep "ip/apply selected table" "$CASE/ip_apply.log" "host table: ip filter"
check_grep "ip/apply selected family" "$CASE/ip_apply.log" "family=ip"
check_grep "ip/apply inserted before Docker" "$CASE/ip_apply.log" \
  "inserted the jump before jump DOCKER-USER (ip filter FORWARD)"
check_state "ip/state table" "table" "ip filter"
check_state "ip/state family" "table_family" "ip"
check_state "ip/state profile" "profile" "proxyarp"
check_state "ip/state uplink" "uplink" "eth0"
check_state "ip/state interfaces" "interfaces" "tap0 eth0"
check_forward_order "ip/jump is first and before DOCKER-USER" "ip filter" "DOCKER-USER"
check_rules_exact "ip/rules are the declared pair only" "ip filter" \
  'iifname tap0 oifname eth0 ip saddr 192.168.1.10/32 ether saddr aa:bb:cc:dd:ee:ff accept' \
  'iifname eth0 oifname tap0 ip daddr 192.168.1.10/32 ether daddr aa:bb:cc:dd:ee:ff accept'
run_here ip_check_after "$PROXYARP_MARKER" --check
check_rc "ip/check after" 0 $?
handle_before="$(jump_handles "ip filter")"
run_here ip_reapply "$PROXYARP_MARKER" --apply
check_rc "ip/idempotent re-apply" 0 $?
check_grep "ip/re-apply no reinsert" "$CASE/ip_reapply.log" "already present in the correct position"
check_eq "ip/re-apply keeps the jump handle" "$handle_before" "$(jump_handles "ip filter")"
check_eq "ip/re-apply keeps one jump" "1" "$(jump_handles "ip filter" | wc -w | tr -d ' ')"
run_here ip_rollback "$PROXYARP_MARKER" --rollback --apply
check_rc "ip/rollback" 0 $?
run_here ip_check_after_rollback "$PROXYARP_MARKER" --check
check_rc "ip/check after rollback" 7 $?
nft list ruleset >"$CASE/after_rollback.nft"
nft -j list ruleset >"$CASE/after_rollback.json"
check_file_eq "ip/rollback restores the ruleset byte-for-byte" \
  "$CASE/before.nft" "$CASE/after_rollback.nft"
check_file_eq "ip/rollback leaves unrelated chains byte-identical (JSON)" \
  "$CASE/before.json" "$CASE/after_rollback.json"

printf '\n=== 3. inet filter + FORWARD: select, apply, rollback ===\n'
new_case inet inet
nft list ruleset >"$CASE/before.nft"
nft -j list ruleset >"$CASE/before.json"
run_here inet_check_before "$PROXYARP_MARKER" --check
check_rc "inet/check before" 7 $?
run_here inet_apply "$PROXYARP_MARKER" --apply
check_rc "inet/apply" 0 $?
check_grep "inet/apply selected table" "$CASE/inet_apply.log" "host table: inet filter"
check_grep "inet/apply selected family" "$CASE/inet_apply.log" "family=inet"
check_state "inet/state table" "table" "inet filter"
check_state "inet/state family" "table_family" "inet"
run_here inet_check_after "$PROXYARP_MARKER" --check
check_rc "inet/check after" 0 $?
run_here inet_rollback "$PROXYARP_MARKER" --rollback --apply
check_rc "inet/rollback" 0 $?
run_here inet_check_after_rollback "$PROXYARP_MARKER" --check
check_rc "inet/check after rollback" 7 $?
nft list ruleset >"$CASE/after_rollback.nft"
nft -j list ruleset >"$CASE/after_rollback.json"
check_file_eq "inet/rollback restores the ruleset byte-for-byte" \
  "$CASE/before.nft" "$CASE/after_rollback.nft"
check_file_eq "inet/rollback leaves unrelated chains byte-identical (JSON)" \
  "$CASE/before.json" "$CASE/after_rollback.json"

printf '\n=== 4. unknown marker key: exit 8 ===\n'
new_case unknown ip
run_here unknown_key_check "$UNKNOWN_MARKER" --check
check_rc "unknown key/check" 8 $?
check_grep "unknown key schema error" "$CASE/unknown_key_check.log" "unknown key 'bogus'"
check_file_absent "unknown key wrote no state" "$STATE_DIR/host-permit/host-permit.state"

printf '\n=== 5. existing jump after Docker jump: check 7, apply repairs ===\n'
new_case misplaced misplaced
run_here misplaced_check "$PROXYARP_MARKER" --check
check_rc "misplaced/check" 7 $?
check_grep "misplaced drift" "$CASE/misplaced_check.log" "jump-misplaced"
run_here misplaced_apply "$PROXYARP_MARKER" --apply
check_rc "misplaced/apply repairs" 0 $?
run_here misplaced_after "$PROXYARP_MARKER" --check
check_rc "misplaced/check after repair" 0 $?
check_forward_order "misplaced/jump is first and before DOCKER-USER" "ip filter" "DOCKER-USER"
check_rules_exact "misplaced/rules preserved" "ip filter" \
  'iifname tap0 oifname eth0 ip saddr 192.168.1.10/32 ether saddr aa:bb:cc:dd:ee:ff accept' \
  'iifname eth0 oifname tap0 ip daddr 192.168.1.10/32 ether daddr aa:bb:cc:dd:ee:ff accept'
check_eq "misplaced/one jump" "1" "$(jump_handles "ip filter" | wc -w | tr -d ' ')"

printf '\n=== 6. live @terra shape: empty DOCKER-USER, DOCKER-FORWARD returns ===\n'
new_case terra_live terra-live
nft list ruleset >"$CASE/before.nft"
run_here terra_live_check "$PROXYARP_MARKER" --check
check_rc "terra-live/check" 7 $?
run_here terra_live_apply "$PROXYARP_MARKER" --apply
check_rc "terra-live/apply" 0 $?
check_forward_order "terra-live/jump inserted first" "ip filter" "DOCKER-USER"
check_docker_chains_untouched "terra-live/Docker chains untouched" "ip filter"
run_here terra_live_after "$PROXYARP_MARKER" --check
check_rc "terra-live/check after" 0 $?
run_here terra_live_rollback "$PROXYARP_MARKER" --rollback --apply
check_rc "terra-live/rollback" 0 $?
nft list ruleset >"$CASE/after_rollback.nft"
check_file_eq "terra-live/rollback restores the ruleset byte-for-byte" \
  "$CASE/before.nft" "$CASE/after_rollback.nft"

printf '\n=== 7. goto DOCKER-* is also a Docker jump boundary ===\n'
new_case goto goto
run_here goto_check "$PROXYARP_MARKER" --check
check_rc "goto/check" 7 $?
run_here goto_apply "$PROXYARP_MARKER" --apply
check_rc "goto/apply" 0 $?
check_grep "goto/apply inserted before goto" "$CASE/goto_apply.log" \
  "inserted the jump before goto DOCKER-USER (ip filter FORWARD)"
check_forward_order "goto/jump is first and before DOCKER-USER" "ip filter" "DOCKER-USER"
run_here goto_after "$PROXYARP_MARKER" --check
check_rc "goto/check after" 0 $?

printf '\n=== 8. bridge profile: tap <-> bridge, optional peer absent ===\n'
new_case bridge ip
run_here bridge_apply "$BRIDGE_MARKER" --apply
check_rc "bridge/apply" 0 $?
check_state "bridge/state table" "table" "ip filter"
check_state "bridge/state profile" "profile" "bridge"
check_state "bridge/state interfaces" "interfaces" "tap0 br0"
check_rules_exact "bridge/rules are the declared pair only" "ip filter" \
  'iifname tap0 oifname br0 accept' \
  'iifname br0 oifname tap0 accept'
run_here bridge_after "$BRIDGE_MARKER" --check
check_rc "bridge/check after" 0 $?

printf '\n=== 9. peer address only: normalised to /32, no ether match ===\n'
new_case address_only ip
run_here address_only_apply "$ADDRESS_ONLY_MARKER" --apply
check_rc "address-only/apply" 0 $?
check_rules_exact "address-only/rules are the declared pair only" "ip filter" \
  'iifname tap0 oifname eth0 ip saddr 192.168.1.10/32 accept' \
  'iifname eth0 oifname tap0 ip daddr 192.168.1.10/32 accept'
check_not_grep "address-only/no MAC match" "$CASE/address_only_apply.log" "ether saddr"
run_here address_only_after "$ADDRESS_ONLY_MARKER" --check
check_rc "address-only/check after" 0 $?

printf '\n=== matrix summary ===\n'
printf '%-5s %-56s %s\n' STATUS CASE RESULT
for row in "${rows[@]}"; do
  IFS='|' read -r status label result <<<"$row"
  printf '%-5s %-56s %s\n' "$status" "$label" "$result"
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
