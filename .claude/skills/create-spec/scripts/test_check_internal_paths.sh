#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_internal_paths.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Case 1: a correct multi-path spec. Api names carry no path, the only non-"/"
# internal_path sits on a DISABLED inheritance ingredient, and no REST name
# repeats across paths.
OUT=$("$SCRIPT" "$DIR/fixtures/internal_paths_good.json")
echo "$OUT" | grep -q "RESULT: PASS (0 warning(s), no errors)" || fail "good: expected clean PASS, got: $OUT"
echo "$OUT" | grep -q "LABEL_AS_PATH" && fail "good: a DISABLED ingredient collection must not be flagged"
echo "good: OK"

# Case 2: strict mode on the three defects.
set +e
OUT=$("$SCRIPT" "$DIR/fixtures/internal_paths_bad.json"); RC=$?
set -e
[ "$RC" -eq 1 ] || fail "bad-strict: exit=$RC want 1"
echo "$OUT" | grep -q "RESULT: FAIL" || fail "bad-strict: expected RESULT: FAIL"
echo "$OUT" | grep -q "NAME_CARRIES_PATH .* api=/v2/getMasterchainInfo" || fail "bad-strict: expected the prefixed api name"
echo "$OUT" | grep -q "LABEL_AS_PATH .* internal_path=WS-ONLY" || fail "bad-strict: expected the enabled label"
echo "$OUT" | grep -q "AMBIGUOUS_REST_NAME .* GET /estimateFee .* /v2, /v3" || fail "bad-strict: expected the ambiguous REST name"
echo "bad-strict: OK"

# Case 3: --warn reports everything and exits 0, for deliberately exercising a
# known-imperfect spec.
OUT=$("$SCRIPT" --warn "$DIR/fixtures/internal_paths_bad.json")
echo "$OUT" | grep -q "RESULT: PASS (warn mode" || fail "bad-warn: expected warn-mode PASS"
echo "$OUT" | grep -q "NAME_CARRIES_PATH" || fail "bad-warn: findings must still be printed"
echo "bad-warn: OK"

# Case 4: a warning alone never blocks — TON ships two on purpose.
cat > /tmp/ip_warn_only.json <<'JSON'
{"proposal":{"specs":[{"index":"WARNONLY","enabled":true,"api_collections":[
 {"enabled":true,"collection_data":{"api_interface":"rest","internal_path":"/v2","type":"POST","add_on":""},"apis":[{"name":"/runGetMethod","enabled":true}]},
 {"enabled":true,"collection_data":{"api_interface":"rest","internal_path":"/v3","type":"POST","add_on":""},"apis":[{"name":"/runGetMethod","enabled":true}]}]}]}}
JSON
OUT=$("$SCRIPT" /tmp/ip_warn_only.json)
echo "$OUT" | grep -q "RESULT: PASS (1 warning(s), no errors)" || fail "warn-only: a warning must not fail the run, got: $OUT"
rm -f /tmp/ip_warn_only.json
echo "warn-only: OK"

# Case 5: two names that differ only inside their placeholders compile to one
# pattern, so the router only ever reaches the last one declared. Reported as a
# warning, and NOT also as AMBIGUOUS_REST_NAME — the names are not equal.
cat > /tmp/ip_shape.json <<'JSON'
{"proposal":{"specs":[{"index":"SHAPE","enabled":true,"api_collections":[
 {"enabled":true,"collection_data":{"api_interface":"rest","internal_path":"","type":"GET","add_on":""},"apis":[
   {"name":"/cosmos/auth/v1beta1/bech32/{address_bytes}","enabled":true},
   {"name":"/cosmos/auth/v1beta1/bech32/{address_string}","enabled":true},
   {"name":"/cosmos/auth/v1beta1/bech32/latest","enabled":true}]}]}]}}
JSON
OUT=$("$SCRIPT" /tmp/ip_shape.json)
echo "$OUT" | grep -q "AMBIGUOUS_REST_SHAPE .*{address_bytes}  ~  .*{address_string}" || fail "shape: expected the shadowed pair, got: $OUT"
echo "$OUT" | grep -q "AMBIGUOUS_REST_NAME" && fail "shape: distinct names must not also be reported as an ambiguous NAME"
echo "$OUT" | grep -q "RESULT: PASS (1 warning(s), no errors)" || fail "shape: a literal sibling compiles to its own pattern and must not be flagged, got: $OUT"
rm -f /tmp/ip_shape.json
echo "shape: OK"

# Case 6: unparseable input fails closed rather than reading as clean.
echo '{ not json' > /tmp/ip_broken.json
set +e
OUT=$("$SCRIPT" /tmp/ip_broken.json 2>&1); RC=$?
set -e
rm -f /tmp/ip_broken.json
[ "$RC" -eq 2 ] || fail "invalid-json: exit=$RC want 2"
echo "$OUT" | grep -q "INVALID_JSON" || fail "invalid-json: expected INVALID_JSON"
echo "invalid-json: OK"

echo "ALL TESTS PASSED"
