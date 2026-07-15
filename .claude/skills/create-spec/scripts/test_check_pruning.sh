#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_pruning.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Case 1: good — retention 1000, values within 3x → exit 0
OUT=$("$SCRIPT" "$DIR/fixtures/pruning_good.json" 1000)
echo "$OUT" | grep -q "RESULT: PASS" || fail "good: expected RESULT: PASS"
echo "good: OK"

# Case 2: bad — retention 800, values 125x too large → exit 1, FAIL rows
set +e
OUT=$("$SCRIPT" "$DIR/fixtures/pruning_bad.json" 800); RC=$?
set -e
[ "$RC" -eq 1 ] || fail "bad: exit=$RC want 1"
echo "$OUT" | grep -q "rule.block" || fail "bad: expected rule.block FAIL row"
echo "$OUT" | grep -q "latest_distance" || fail "bad: expected latest_distance FAIL row"
echo "bad: OK"

# Case 3: unknown retention — INFO, exit 0 (never block)
OUT=$("$SCRIPT" "$DIR/fixtures/pruning_bad.json" unknown)
echo "$OUT" | grep -q "INFO: retention unknown" || fail "unknown: expected INFO line"
echo "$OUT" | grep -q "RESULT: PASS" || fail "unknown: expected RESULT: PASS"
echo "unknown: OK"

echo "ALL TESTS PASSED"
