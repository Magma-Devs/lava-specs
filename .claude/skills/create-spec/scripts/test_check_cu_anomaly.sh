#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_cu_anomaly.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Case 1: varied — exit 0, RESULT: PASS
OUT=$("$SCRIPT" "$DIR/fixtures/cu_varied.json")
echo "$OUT" | grep -q "RESULT: PASS" || fail "varied: expected RESULT: PASS"
echo "varied: OK"

# Case 2: uniform — exit 1, FAIL row naming the index
set +e
OUT=$("$SCRIPT" "$DIR/fixtures/cu_uniform.json"); RC=$?
set -e
[ "$RC" -eq 1 ] || fail "uniform: exit=$RC want 1"
echo "$OUT" | grep -q "UNIFORM" || fail "uniform: expected UNIFORM FAIL row"
echo "uniform: OK"

# Case 3: import-only entry (no api_collections) alongside a uniform offender —
# the unguarded jq would error and false-PASS; the ?-guard must still catch OFFENDER.
set +e
OUT=$("$SCRIPT" "$DIR/fixtures/cu_import_only.json"); RC=$?
set -e
[ "$RC" -eq 1 ] || fail "import_only: exit=$RC want 1 (offender must still be flagged)"
echo "$OUT" | grep -q "jq: error" && fail "import_only: jq errored on null api_collections"
echo "$OUT" | grep -q "OFFENDER" || fail "import_only: expected OFFENDER FAIL row"
echo "import_only: OK"

echo "ALL TESTS PASSED"
