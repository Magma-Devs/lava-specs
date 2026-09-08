#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_parent_duplication.sh"
FIX="$DIR/fixtures"
ALLOW="$FIX/parentdup_allow.txt"
NONE=/dev/null
fail() { echo "FAIL: $1" >&2; exit 1; }

# Case 1: clean child — imports the base, adds only its own method
OUT=$("$SCRIPT" "$FIX/parentdup_clean.json" --allow "$NONE")
echo "$OUT" | grep -q "RESULT: PASS" || fail "clean: expected PASS"
echo "clean: OK"

# Case 2: redundant — re-declares an enabled method the parent already supplies
set +e; OUT=$("$SCRIPT" "$FIX/parentdup_redundant.json" --allow "$NONE"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "redundant: exit=$RC want 1"
echo "$OUT" | grep -q "REDUNDANT|PDREDUN" || fail "redundant: expected REDUNDANT row"
echo "$OUT" | grep -q "fake_a" || fail "redundant: expected the method name"
echo "redundant: OK"

# Case 3: an "enabled": false override of a parent method is the documented
# positive-evidence disable, never a finding
OUT=$("$SCRIPT" "$FIX/parentdup_disabled.json" --allow "$NONE")
echo "$OUT" | grep -q "RESULT: PASS" || fail "disabled: expected PASS"
echo "disabled: OK"

# Case 4: unimported — retypes the base's surface without importing it (the TRAC bug)
set +e; OUT=$("$SCRIPT" "$FIX/parentdup_unimported.json" --threshold 2 --min-fanin 1 --allow "$NONE"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "unimported: exit=$RC want 1"
echo "$OUT" | grep -q "UNIMPORTED|PDUNIMP" || fail "unimported: expected UNIMPORTED row"
echo "unimported: OK"

# Case 5: under the threshold it is not a finding
OUT=$("$SCRIPT" "$FIX/parentdup_unimported.json" --threshold 99 --min-fanin 1 --allow "$NONE")
echo "$OUT" | grep -q "RESULT: PASS" || fail "threshold: expected PASS above threshold"
echo "threshold: OK"

# Case 6: the exception ledger silences both rules, and says why in the PASS rows
OUT=$("$SCRIPT" "$FIX/parentdup_unimported.json" --threshold 2 --min-fanin 1 --allow "$ALLOW")
echo "$OUT" | grep -q "RESULT: PASS" || fail "allow: expected PASS for ledgered exception"
echo "$OUT" | grep -q "allowed: fixture" || fail "allow: expected the reason echoed"
OUT=$("$SCRIPT" "$FIX/parentdup_redundant.json" --allow "$ALLOW")
echo "$OUT" | grep -q "RESULT: PASS" || fail "allow: expected PASS for ledgered REDUNDANT"
echo "allow: OK"

# Case 7: usage errors
set +e; "$SCRIPT" >/dev/null 2>&1; RC=$?; set -e
[ "$RC" -eq 2 ] || fail "usage: exit=$RC want 2"
set +e; "$SCRIPT" "$FIX/parentdup_clean.json" --threshold x >/dev/null 2>&1; RC=$?; set -e
[ "$RC" -eq 2 ] || fail "usage: bad threshold exit=$RC want 2"
echo "usage: OK"



# Case 8: the fan-in cut keeps sibling chain specs out of the base list — a spec
# with too few importers is not a base, so its methods are not "retyped". The
# fixture base has 3 importers (clean, redundant, disabled), so a cut of 4
# excludes it and the same file that FAILs at --min-fanin 1 must PASS here.
OUT=$("$SCRIPT" "$FIX/parentdup_unimported.json" --threshold 2 --min-fanin 4 --allow "$NONE")
echo "$OUT" | grep -q "RESULT: PASS" || fail "fanin: expected PASS above the fan-in cut"
set +e; "$SCRIPT" "$FIX/parentdup_clean.json" --min-fanin x >/dev/null 2>&1; RC=$?; set -e
[ "$RC" -eq 2 ] || fail "usage: bad min-fanin exit=$RC want 2"
echo "fanin: OK"

# Case 9: with NO --allow, the ledger must resolve to spec-inheritance-exceptions.txt
# beside the spec. CI checks out to a different absolute path than a dev's repo,
# and every case above passes an explicit --allow, so nothing else pins this.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$FIX/parentdup_base.json" "$FIX/parentdup_clean.json" "$FIX/parentdup_redundant.json" "$TMP/"
printf 'PDREDUN REDUNDANT fake_a  # default-path fixture\n' > "$TMP/spec-inheritance-exceptions.txt"
OUT=$("$SCRIPT" "$TMP/parentdup_redundant.json")
echo "$OUT" | grep -q "RESULT: PASS" || fail "default-allow: ledger beside the spec was not picked up"
echo "$OUT" | grep -q "allowed: default-path fixture" || fail "default-allow: expected the reason echoed"
rm "$TMP/spec-inheritance-exceptions.txt"
set +e; OUT=$("$SCRIPT" "$TMP/parentdup_redundant.json"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "default-allow: exit=$RC want 1 with no ledger present"
echo "default-allow: OK"

echo "ALL TESTS PASSED"
