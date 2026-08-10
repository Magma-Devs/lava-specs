#!/usr/bin/env bash
# Tests for check_directive_presence.sh — builds a throwaway spec dir with a
# standalone spec, a parent+child inheritance pair, a head-only spec, and a
# truly-missing spec, then asserts the inheritance-aware presence check
# classifies each correctly.

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_directive_presence.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

dirset='[{"function_tag":"GET_BLOCKNUM"},{"function_tag":"GET_BLOCK_BY_NUM"}]'

# standalone spec that defines both directives → OK
cat > "$T/standalone.json" <<EOF
{"proposal":{"specs":[{"index":"STAND","imports":[],"api_collections":[{"parse_directives":$dirset}]}]},"deposit":"x"}
EOF
# parent defines directives; child imports parent with EMPTY directives → OK via inheritance
cat > "$T/parent.json" <<EOF
{"proposal":{"specs":[{"index":"PARENT","imports":[],"api_collections":[{"parse_directives":$dirset}]}]},"deposit":"x"}
EOF
cat > "$T/child.json" <<EOF
{"proposal":{"specs":[{"index":"CHILD","imports":["PARENT"],"api_collections":[{"parse_directives":[]}]}]},"deposit":"x"}
EOF
# head-only: GET_BLOCKNUM present, GET_BLOCK_BY_NUM absent → INFO + OK (exit 0).
# This is the shape of a chain with no blocks (Canton); smart-router #245 added
# head-only chain tracking, so the missing tag is deliberate, not a defect.
cat > "$T/headonly.json" <<EOF
{"proposal":{"specs":[{"index":"HEADONLY","imports":[],"api_collections":[{"parse_directives":[{"function_tag":"GET_BLOCKNUM"}]}]}]},"deposit":"x"}
EOF
# truly missing: standalone, no directives, no imports → FAIL
cat > "$T/missing.json" <<EOF
{"proposal":{"specs":[{"index":"MISS","imports":[],"api_collections":[{"parse_directives":[]}]}]},"deposit":"x"}
EOF

OUT=$(bash "$SCRIPT" "$T/standalone.json"); [ "$OUT" = "OK" ] || fail "standalone: got '$OUT', want OK"
echo "standalone: OK"

OUT=$(bash "$SCRIPT" "$T/child.json"); [ "$OUT" = "OK" ] || fail "child(inherited): got '$OUT', want OK"
echo "child-inherited: OK"

bash "$SCRIPT" "$T/headonly.json" >/dev/null 2>&1 || fail "head-only: expected exit 0"
OUT=$(bash "$SCRIPT" "$T/headonly.json")
echo "$OUT" | grep -q "^INFO: GET_BLOCK_BY_NUM absent" || fail "head-only: got '$OUT', want an INFO line"
echo "$OUT" | grep -qx "OK" || fail "head-only: got '$OUT', want OK verdict"
echo "head-only: OK"

if bash "$SCRIPT" "$T/missing.json" >/dev/null 2>&1; then fail "missing: expected non-zero exit"; fi
OUT=$(bash "$SCRIPT" "$T/missing.json" 2>&1 || true)
echo "$OUT" | grep -q "FAIL missing" || fail "missing: got '$OUT', want FAIL"
echo "truly-missing: OK"

echo "ALL TESTS PASSED"
