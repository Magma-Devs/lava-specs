#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_disabled_count.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# none disabled, claim 0 -> pass
OUT=$("$SCRIPT" "$DIR/fixtures/disabled_count_none.json" --expect 0)
echo "$OUT" | grep -q "RESULT: PASS" || fail "none/0: expected PASS"
echo "none-vs-0: OK"

# three disabled, claim 3 -> pass, and all three names reported
OUT=$("$SCRIPT" "$DIR/fixtures/disabled_count_three.json" --expect 3)
echo "$OUT" | grep -q "RESULT: PASS" || fail "three/3: expected PASS"
for m in a_one a_three a_four; do
  echo "$OUT" | grep -q "$m" || fail "three/3: expected $m in the report"
done
echo "$OUT" | grep -q "a_two" && fail "three/3: a_two is enabled, must not be listed"
echo "three-vs-3: OK"

# three disabled, claim 12 -> exit 1 (the #125 shape)
set +e; OUT=$("$SCRIPT" "$DIR/fixtures/disabled_count_three.json" --expect 12); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "three/12: exit=$RC want 1"
echo "$OUT" | grep -q "MISMATCH | claimed=12 | actual=3" || fail "three/12: expected the MISMATCH row"
echo "three-vs-12: OK"

# body claiming zero against a file that disables three -> exit 1 (the #130 shape)
set +e; OUT=$("$SCRIPT" "$DIR/fixtures/disabled_count_three.json" --body "$DIR/fixtures/disabled_count_body_zero.md"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "body-zero: exit=$RC want 1"
echo "$OUT" | grep -q "claimed=0" || fail "body-zero: expected claimed=0 parsed from the body"
echo "body-zero-vs-three: OK"

# body claiming three against a file that disables three -> pass
OUT=$("$SCRIPT" "$DIR/fixtures/disabled_count_three.json" --body "$DIR/fixtures/disabled_count_body_three.md")
echo "$OUT" | grep -q "RESULT: PASS" || fail "body-three: expected PASS"
echo "body-three-vs-three: OK"

# no claim at all -> report only, never fails
OUT=$("$SCRIPT" "$DIR/fixtures/disabled_count_three.json")
echo "$OUT" | grep -q "RESULT: PASS (report only)" || fail "no-claim: expected report-only PASS"
echo "no-claim: OK"

# unparseable input fails closed
echo 'not json' > /tmp/dc_bad.json
set +e; "$SCRIPT" /tmp/dc_bad.json --expect 0 >/dev/null 2>&1; RC=$?; set -e
[ "$RC" -eq 2 ] || fail "bad-json: exit=$RC want 2"
echo "bad-json: OK"

echo "ALL TESTS PASSED"
