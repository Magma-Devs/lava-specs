#!/usr/bin/env bash
# Smoke tests for compare_spec_methods.sh. Feeds wanted-method lists via stdin
# and asserts the script's section counts. Exits non-zero on failure.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/compare_spec_methods.sh"
SPEC="$DIR/fixtures/methods_sample.json"   # serves eth_blockNumber, eth_getBalance

fail() { echo "FAIL: $1" >&2; exit 1; }

sec() {  # $1=OUT  $2=section regex -> count of non-empty rows
  echo "$1" | awk -v h="$2" 'index($0,h)==1{f=1;next} /^=== /{f=0} f && NF' | wc -l
}

# Case 1: exact match — PRESENT=2, MISSING=0, EXTRA=0
OUT=$(printf 'eth_blockNumber\neth_getBalance\n' | "$SCRIPT" "$SPEC" -)
echo "$OUT" | grep -q "^=== PRESENT" || fail "good: no PRESENT section"
[ "$(sec "$OUT" '=== PRESENT')" -eq 2 ]        || fail "good: PRESENT != 2"
[ "$(sec "$OUT" '=== MISSING')" -eq 0 ]        || fail "good: MISSING != 0"
[ "$(sec "$OUT" '=== EXTRA IN SPEC')" -eq 0 ]  || fail "good: EXTRA != 0"
echo "good: OK"

# Case 2: list has an unknown method + omits one spec method
#   wanted = {eth_blockNumber, eth_notARealMethod}
#   -> PRESENT=1, MISSING=1 (eth_notARealMethod), EXTRA=1 (eth_getBalance)
OUT=$(printf 'eth_blockNumber\neth_notARealMethod\n' | "$SCRIPT" "$SPEC" -)
[ "$(sec "$OUT" '=== PRESENT')" -eq 1 ]        || fail "diff: PRESENT != 1"
[ "$(sec "$OUT" '=== MISSING')" -eq 1 ]        || fail "diff: MISSING != 1"
[ "$(sec "$OUT" '=== EXTRA IN SPEC')" -eq 1 ]  || fail "diff: EXTRA != 1"
echo "diff: OK"

# Case 3: comments and blank lines in the wanted list are ignored
OUT=$(printf '# header comment\n\neth_blockNumber  # inline\neth_getBalance\n' | "$SCRIPT" "$SPEC" -)
[ "$(sec "$OUT" '=== PRESENT')" -eq 2 ]        || fail "comments: PRESENT != 2"
[ "$(sec "$OUT" '=== MISSING')" -eq 0 ]        || fail "comments: MISSING != 0"
echo "comments: OK"

echo "ALL TESTS PASSED"
