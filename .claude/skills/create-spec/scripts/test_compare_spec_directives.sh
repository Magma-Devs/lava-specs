#!/usr/bin/env bash
# Smoke tests for compare_spec_directives.sh. Runs three fixture cases
# and asserts the script's section counts. Exits non-zero on failure.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/compare_spec_directives.sh"
SPEC="$DIR/fixtures/sample_spec.json"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Case 1: good — PRESENT=3, MISSING=0, EXTRA=0, HASH-MISMATCH=0
OUT=$("$SCRIPT" "$SPEC" "$DIR/fixtures/sample_directives_good.txt")
echo "$OUT" | grep -q "^=== PRESENT" || fail "good: no PRESENT section"
PRESENT=$(echo "$OUT" | awk '/^=== PRESENT/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
MISSING=$(echo "$OUT" | awk '/^=== MISSING/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
HASHMM=$(echo "$OUT" | awk '/^=== HASH-MISMATCH/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$PRESENT" -eq 3 ] || fail "good: PRESENT=$PRESENT, want 3"
[ "$MISSING" -eq 0 ] || fail "good: MISSING=$MISSING, want 0"
[ "$HASHMM" -eq 0 ] || fail "good: HASH-MISMATCH=$HASHMM, want 0"
echo "good: OK"

# Case 2: missing — MISSING=1 (GET_EARLIEST_BLOCK), EXTRA=1 (GET_BLOCK_BY_NUM in spec but not in file)
OUT=$("$SCRIPT" "$SPEC" "$DIR/fixtures/sample_directives_missing.txt")
MISSING=$(echo "$OUT" | awk '/^=== MISSING/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
EXTRA=$(echo "$OUT" | awk '/^=== EXTRA IN SPEC/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$MISSING" -eq 1 ] || fail "missing: MISSING=$MISSING, want 1"
[ "$EXTRA" -eq 1 ] || fail "missing: EXTRA=$EXTRA, want 1"
echo "missing: OK"

# Case 3: hashmismatch — HASH-MISMATCH=1
OUT=$("$SCRIPT" "$SPEC" "$DIR/fixtures/sample_directives_hashmismatch.txt")
HASHMM=$(echo "$OUT" | awk '/^=== HASH-MISMATCH/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$HASHMM" -eq 1 ] || fail "hashmismatch: HASH-MISMATCH=$HASHMM, want 1"
echo "hashmismatch: OK"

echo "ALL TESTS PASSED"
