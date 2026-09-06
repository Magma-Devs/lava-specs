#!/usr/bin/env bash
# Tests for check_hanging_api.sh — builds a throwaway spec dir covering each of
# the three rules, the inheritance case, and the boundary conditions of the
# CU-implied floor.
#
# Requires bash >= 4 for `declare -A` in the script under test (see TESTING.md).

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_hanging_api.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

api() { # name cu timeout hanging
  local extra=""
  [[ "$3" != "0" ]] && extra="\"timeout_ms\":$3,"
  echo "{\"name\":\"$1\",\"compute_units\":$2,$extra\"category\":{\"stateful\":1,\"hanging_api\":$4}}"
}
spec() { # file index imports directives apis
  cat > "$T/$1" <<EOF
{"proposal":{"specs":[{"index":"$2","imports":$3,"api_collections":[
  {"collection_data":{"api_interface":"jsonrpc"},"parse_directives":$4,"apis":[$5]}]}]},"deposit":"x"}
EOF
}

sub='[{"function_tag":"SUBSCRIBE","api_name":"chain_subscribeNewHead"}]'
nodir='[]'

# 1. clean: hanging, not subscribed, timeout above the CU floor → PASS
spec good.json GOOD '[]' "$nodir" "$(api author_submitExtrinsic 10 15000 true)"
bash "$SCRIPT" "$T/good.json" >/dev/null 2>&1 || fail "good: expected exit 0"
echo "clean-hanging: OK"

# 2. hanging_api on a SUBSCRIBE-tagged API → FAIL (rule 1)
spec onsub.json ONSUB '[]' "$sub" "$(api chain_subscribeNewHead 1000 120000 true)"
if bash "$SCRIPT" "$T/onsub.json" >/dev/null 2>&1; then fail "onsub: expected non-zero exit"; fi
OUT=$(bash "$SCRIPT" "$T/onsub.json" 2>&1 || true)
grep -q "SUBSCRIBE-tagged API" <<<"$OUT" || fail "onsub: got '$OUT'"
echo "hanging-on-subscribe: OK"

# rule 1 must win over rules 2/3 — a subscribed API is never judged on its timeout
grep -q "below the CU-implied" <<<"$OUT" && fail "onsub: should not also report a timeout row"
echo "rule-1-precedence: OK"

# 3. hanging_api: true with no timeout_ms → FAIL (rule 2, SKILL.md:263)
spec noto.json NOTO '[]' "$nodir" "$(api eth_sendRawTransaction 10 0 true)"
if bash "$SCRIPT" "$T/noto.json" >/dev/null 2>&1; then fail "noto: expected non-zero exit"; fi
OUT=$(bash "$SCRIPT" "$T/noto.json" 2>&1 || true)
grep -q "no timeout_ms" <<<"$OUT" || fail "noto: got '$OUT'"
echo "missing-timeout: OK"

# 4. timeout_ms below the CU-implied floor → FAIL (rule 3) — the Acala case:
#    cu=1000 implies 100000ms, so a reflexive 30000 shortens the budget.
spec short.json SHORT '[]' "$nodir" "$(api author_submitAndWatchExtrinsic 1000 30000 true)"
if bash "$SCRIPT" "$T/short.json" >/dev/null 2>&1; then fail "short: expected non-zero exit"; fi
OUT=$(bash "$SCRIPT" "$T/short.json" 2>&1 || true)
grep -q "SHORTENS the relay budget" <<<"$OUT" || fail "short: got '$OUT'"
grep -q "below the CU-implied 100000ms" <<<"$OUT" || fail "short: wrong implied floor in '$OUT'"
echo "timeout-shortens: OK"

# 5. same CU, a timeout above the floor → PASS (the fix for case 4)
spec long.json LONG '[]' "$nodir" "$(api author_submitAndWatchExtrinsic 1000 120000 true)"
bash "$SCRIPT" "$T/long.json" >/dev/null 2>&1 || fail "long: expected exit 0"
echo "timeout-raised: OK"

# 6. the 1s floor: GetTimePerCu floors at 1s, so cu=1 implies 1000ms not 100ms.
#    999 must fail, 1000 must pass.
spec floorbad.json FLOORBAD '[]' "$nodir" "$(api tiny 1 999 true)"
if bash "$SCRIPT" "$T/floorbad.json" >/dev/null 2>&1; then fail "floorbad: expected non-zero exit"; fi
grep -q "below the CU-implied 1000ms" <<<"$(bash "$SCRIPT" "$T/floorbad.json" 2>&1 || true)" \
  || fail "floorbad: floor not applied"
spec floorok.json FLOOROK '[]' "$nodir" "$(api tiny 1 1000 true)"
bash "$SCRIPT" "$T/floorok.json" >/dev/null 2>&1 || fail "floorok: expected exit 0 at exactly the floor"
echo "cu-floor-boundary: OK"

# 7. non-hanging APIs are out of scope entirely — no timeout, no subscription check
spec ignore.json IGNORE '[]' "$sub" "$(api chain_subscribeNewHead 1000 0 false)"
bash "$SCRIPT" "$T/ignore.json" >/dev/null 2>&1 || fail "ignore: non-hanging APIs must be ignored"
echo "non-hanging-ignored: OK"

# 8. inheritance: the SUBSCRIBE directive lives in the PARENT, the hanging API in
#    the child whose own parse_directives are empty (the ETH1-import shape).
spec iparent.json IPARENT '[]' "$sub" "$(api noop 10 5000 false)"
spec ichild.json ICHILD '["IPARENT"]' "$nodir" "$(api chain_subscribeNewHead 1000 120000 true)"
if bash "$SCRIPT" "$T/ichild.json" >/dev/null 2>&1; then fail "ichild: expected non-zero exit"; fi
grep -q "SUBSCRIBE-tagged API" <<<"$(bash "$SCRIPT" "$T/ichild.json" 2>&1 || true)" \
  || fail "ichild: inherited SUBSCRIBE directive not resolved"
echo "inherited-subscribe: OK"

# 9. a spec with no hanging APIs at all → PASS with empty sections
spec none.json NONE '[]' "$nodir" "$(api eth_call 10 0 false)"
bash "$SCRIPT" "$T/none.json" >/dev/null 2>&1 || fail "none: expected exit 0"
echo "no-hanging-apis: OK"

echo "ALL TESTS PASSED"
