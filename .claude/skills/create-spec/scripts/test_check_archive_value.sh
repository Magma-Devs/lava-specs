#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_archive_value.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# good: GBN+integer, distance-based, and canto-shape (ft none) all pass
OUT=$("$SCRIPT" "$DIR/fixtures/archive_value_good.json")
echo "$OUT" | grep -q "RESULT: PASS" || fail "good: expected RESULT: PASS"
echo "good: OK"

# bad: GBN + no latest_distance + "*" → exit 1 with a FAIL row
set +e; OUT=$("$SCRIPT" "$DIR/fixtures/archive_value_bad.json"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "bad: exit=$RC want 1"
echo "$OUT" | grep -q 'expected_value="\*"' || fail "bad: expected the '*' FAIL row"
echo "bad: OK"

echo "ALL TESTS PASSED"
