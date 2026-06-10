#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_network_params.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Case 1: good — exit 0, no FAIL rows
OUT=$("$SCRIPT" "$DIR/fixtures/network_params_good.json")
echo "$OUT" | grep -q "^=== PASS" || fail "good: no PASS section"
FAIL_ROWS=$(echo "$OUT" | awk '/^=== FAIL/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$FAIL_ROWS" -eq 0 ] || fail "good: FAIL rows=$FAIL_ROWS, want 0"
echo "good: OK"

# Case 2: bad — exit 1, FAIL rows present
set +e
OUT=$("$SCRIPT" "$DIR/fixtures/network_params_bad.json")
RC=$?
set -e
[ "$RC" -eq 1 ] || fail "bad: exit code=$RC, want 1"
FAIL_ROWS=$(echo "$OUT" | awk '/^=== FAIL/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$FAIL_ROWS" -ge 4 ] || fail "bad: FAIL rows=$FAIL_ROWS, want >=4"
echo "bad: OK"

echo "ALL TESTS PASSED"
