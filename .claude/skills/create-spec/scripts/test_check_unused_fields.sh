#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_unused_fields.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Case 1: clean spec — no removed fields → RESULT: PASS, exit 0
OUT=$("$SCRIPT" "$DIR/fixtures/unused_fields_good.json")
echo "$OUT" | grep -q "RESULT: PASS (no removed fields)" || fail "good: expected clean PASS"
echo "good: OK"

# Case 2: legacy spec, strict — removed fields present → exit 1, RESULT: FAIL, paths reported.
# Exercises envelope (title/deposit), spec-level (min_stake_provider), nested category
# (local/subscription), and a second spec object (multiple specs in one file).
set +e
OUT=$("$SCRIPT" "$DIR/fixtures/unused_fields_bad.json"); RC=$?
set -e
[ "$RC" -eq 1 ] || fail "bad-strict: exit=$RC want 1"
echo "$OUT" | grep -q "RESULT: FAIL" || fail "bad-strict: expected RESULT: FAIL"
echo "$OUT" | grep -q "proposal.title" || fail "bad-strict: expected proposal.title path"
echo "$OUT" | grep -qx "REMOVED_FIELD | $DIR/fixtures/unused_fields_bad.json | deposit" || fail "bad-strict: expected top-level deposit path"
echo "$OUT" | grep -q "min_stake_provider" || fail "bad-strict: expected min_stake_provider path"
echo "$OUT" | grep -qE "category\.(local|subscription)" || fail "bad-strict: expected nested category.local/subscription path"
echo "bad-strict: OK"

# Case 3: legacy spec, warn mode — reported but not blocking → exit 0, findings still printed
OUT=$("$SCRIPT" --warn "$DIR/fixtures/unused_fields_bad.json")
echo "$OUT" | grep -q "RESULT: PASS (warn mode" || fail "bad-warn: expected warn-mode PASS"
echo "$OUT" | grep -q "REMOVED_FIELD" || fail "bad-warn: expected findings still reported"
echo "bad-warn: OK"

echo "ALL TESTS PASSED"
