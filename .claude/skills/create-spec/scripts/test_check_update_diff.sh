#!/usr/bin/env bash
# Tests for check_update_diff.sh — the declared-diff guard used by update mode.
# Asserts that every class of change is classified correctly: declared additions
# and declared drift fixes PASS; undeclared edits, deletions, identity changes
# and probe-only disables FAIL. Exits non-zero on failure.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_update_diff.sh"
F="$DIR/fixtures"

TDIR=$(mktemp -d "${TMPDIR:-/tmp}/check_update_diff_test.XXXXXX")
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# run <base> <cand> <plan> -> sets OUT and RC
run() {
  set +e
  OUT=$("$SCRIPT" "$1" "$2" "$3" 2>&1)
  RC=$?
  set -e
}

plan() { printf "$1" > "$TDIR/plan.tsv"; echo "$TDIR/plan.tsv"; }

API='S:DEMO|C:jsonrpc~~POST~|A:demo_blockNumber'
NEW='S:DEMO|C:jsonrpc~~POST~|A:demo_getProof'
EXT='S:DEMO|C:jsonrpc~~POST~|E:archive'

# 1. No change at all, empty plan -> PASS (the guard must not invent work).
: > "$TDIR/empty.tsv"
run "$F/update_base.json" "$F/update_base.json" "$TDIR/empty.tsv"
[ "$RC" -eq 0 ] || fail "noop: expected PASS, got rc=$RC"
echo "$OUT" | grep -q "RESULT: PASS" || fail "noop: no PASS line"
echo "noop: OK"

# 2. Additions declared in the plan -> PASS.
P=$(plan "ADD\t$NEW\t-\tnew method\thttps://docs/getProof\nADD\t$EXT\t-\tarchive\thttps://docs/archive\n")
run "$F/update_base.json" "$F/update_added.json" "$P"
[ "$RC" -eq 0 ] || fail "declared-add: expected PASS, got rc=$RC ($OUT)"
echo "$OUT" | grep -q "2 added" || fail "declared-add: count wrong"
echo "declared-add: OK"

# 3. The same additions with nothing declared -> FAIL, one row each.
run "$F/update_base.json" "$F/update_added.json" "$TDIR/empty.tsv"
[ "$RC" -eq 1 ] || fail "undeclared-add: expected FAIL"
[ "$(echo "$OUT" | grep -c '^undeclared-add|')" -eq 2 ] || fail "undeclared-add: expected 2 rows"
echo "undeclared-add: OK"

# 4. A declared drift fix with evidence -> PASS.
P=$(plan "MODIFY\t$API\tcompute_units\t10 -> 15\thttps://docs/cu-table\n")
run "$F/update_base.json" "$F/update_modified.json" "$P"
[ "$RC" -eq 0 ] || fail "declared-modify: expected PASS, got rc=$RC ($OUT)"
echo "$OUT" | grep -q "1 modified" || fail "declared-modify: count wrong"
echo "declared-modify: OK"

# 5. The same fix with an empty EVIDENCE column -> FAIL, and exactly once (a row
#    that was applied but rejected must not ALSO be reported as not-applied).
P=$(plan "MODIFY\t$API\tcompute_units\t10 -> 15\t\n")
run "$F/update_base.json" "$F/update_modified.json" "$P"
[ "$RC" -eq 1 ] || fail "no-evidence: expected FAIL"
echo "$OUT" | grep -q '^no-evidence|' || fail "no-evidence: missing row"
echo "$OUT" | grep -q "RESULT: FAIL (1 violation" || fail "no-evidence: expected exactly 1 violation"
echo "no-evidence: OK"

# 6. An undeclared drift fix -> FAIL. This is the PR #80 failure mode: a silent
#    value change that every other guard passes.
run "$F/update_base.json" "$F/update_modified.json" "$TDIR/empty.tsv"
[ "$RC" -eq 1 ] || fail "undeclared-modify: expected FAIL"
echo "$OUT" | grep -q '^undeclared-modify|' || fail "undeclared-modify: missing row"
echo "undeclared-modify: OK"

# 7. A deleted api -> FAIL, and no plan may authorize it.
P=$(plan "ADD\t$NEW\t-\t-\t-\n")
run "$F/update_base.json" "$F/update_removed.json" "$P"
[ "$RC" -eq 1 ] || fail "removed: expected FAIL"
echo "$OUT" | grep -q '^removed-target|' || fail "removed: missing removed-target row"
echo "removed: OK"

# 8. A renamed api is a delete + an add, and cannot be laundered as a MODIFY of
#    the name field.
P=$(plan "MODIFY\t$API\tname\trename\thttps://docs\n")
run "$F/update_base.json" "$F/update_renamed.json" "$P"
[ "$RC" -eq 1 ] || fail "rename: expected FAIL"
echo "$OUT" | grep -q '^removed-target|' || fail "rename: missing removed-target"
echo "$OUT" | grep -q '^undeclared-add|' || fail "rename: missing undeclared-add"
echo "rename: OK"

# 9. Identity/structure fields are refused even when declared with evidence.
P=$(plan "MODIFY\tS:DEMOT\timports[0]\tre-parent\thttps://docs\n")
run "$F/update_base.json" "$F/update_forbidden.json" "$P"
[ "$RC" -eq 1 ] || fail "forbidden: expected FAIL"
echo "$OUT" | grep -q '^forbidden-field|' || fail "forbidden: missing forbidden-field row"
echo "forbidden: OK"

# 10. Disabling on probe evidence alone is refused (free-tier rule); the same
#     disable with documentation evidence passes.
jq --indent 4 '(.proposal.specs[0].api_collections[0].apis[0].enabled) = false' \
  "$F/update_base.json" > "$TDIR/disabled.json"
P=$(plan "MODIFY\t$API\tenabled\tdisable\tprobe:-32601 on node1\n")
run "$F/update_base.json" "$TDIR/disabled.json" "$P"
[ "$RC" -eq 1 ] || fail "probe-disable: expected FAIL"
echo "$OUT" | grep -q '^probe-only-disable|' || fail "probe-disable: missing row"
P=$(plan "MODIFY\t$API\tenabled\tdisable\thttps://docs/removed-in-v2\n")
run "$F/update_base.json" "$TDIR/disabled.json" "$P"
[ "$RC" -eq 0 ] || fail "docs-disable: expected PASS, got rc=$RC ($OUT)"
echo "disable-evidence: OK"

# 11. A plan row that never landed in the file -> FAIL (the plan is a contract in
#     both directions).
P=$(plan "ADD\t$NEW\t-\t-\t-\n")
run "$F/update_base.json" "$F/update_base.json" "$P"
[ "$RC" -eq 1 ] || fail "not-applied: expected FAIL"
echo "$OUT" | grep -q '^not-applied|' || fail "not-applied: missing row"
echo "not-applied: OK"

# 12. Declaring the parent covers its children: one ADD row for a new collection
#     authorizes every api inside it.
jq --indent 4 '(.proposal.specs[0].api_collections) += [{
    "enabled": true,
    "collection_data": { "api_interface": "rest", "internal_path": "/v2", "type": "GET", "add_on": "" },
    "apis": [ { "name": "/status", "block_parsing": { "parser_arg": ["latest"], "parser_func": "DEFAULT" },
                "compute_units": 10, "enabled": true, "category": { "deterministic": true, "stateful": 0 } } ],
    "headers": [], "inheritance_apis": [], "parse_directives": [], "verifications": [], "extensions": []
  }]' "$F/update_base.json" > "$TDIR/newcoll.json"
P=$(plan "ADD\tS:DEMO|C:rest~/v2~GET~\t-\tnew REST surface\thttps://docs/v2\n")
run "$F/update_base.json" "$TDIR/newcoll.json" "$P"
[ "$RC" -eq 0 ] || fail "add-covers-children: expected PASS, got rc=$RC ($OUT)"
echo "add-covers-children: OK"

# 13. Malformed input fails closed rather than passing vacuously.
printf '{ not json' > "$TDIR/broken.json"
run "$F/update_base.json" "$TDIR/broken.json" "$TDIR/empty.tsv"
[ "$RC" -eq 2 ] || fail "broken-json: expected rc=2, got $RC"
echo "$OUT" | grep -q "RESULT: FAIL" || fail "broken-json: no FAIL line"
echo "broken-json: OK"

# 14. --emit seeds a plan that, once evidence is filled in, passes the guard.
"$SCRIPT" --emit "$F/update_base.json" "$F/update_added.json" \
  | grep -v '^#' | awk -F'\t' 'NF{print $1"\t"$2"\t"$3"\t"$4"\thttps://docs/evidence"}' > "$TDIR/emitted.tsv"
run "$F/update_base.json" "$F/update_added.json" "$TDIR/emitted.tsv"
[ "$RC" -eq 0 ] || fail "emit-roundtrip: expected PASS, got rc=$RC ($OUT)"
echo "emit-roundtrip: OK"

echo "ALL TESTS PASSED"
