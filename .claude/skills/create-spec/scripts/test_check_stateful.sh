#!/usr/bin/env bash
# Tests for check_stateful.sh — a throwaway spec dir covering the curated write
# list, the curated read list, REST verb disambiguation, and the advisory
# consensus layer including its threshold and its dedupe key.
#
# Requires bash >= 4 for `declare -A` in the script under test (see TESTING.md).

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_stateful.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

api() { # name stateful
  echo "{\"name\":\"$1\",\"compute_units\":10,\"enabled\":true,\"category\":{\"deterministic\":false,\"stateful\":$2}}"
}
# jsonrpc collection
spec() { # file index apis...
  local f=$1 idx=$2; shift 2
  local IFS=,
  cat > "$T/$f" <<EOF
{"proposal":{"specs":[{"index":"$idx","imports":[],"api_collections":[
  {"collection_data":{"api_interface":"jsonrpc"},"parse_directives":[],"apis":[$*]}]}]},"deposit":"x"}
EOF
}
# rest collection with an explicit HTTP verb
restspec() { # file index type apis...
  local f=$1 idx=$2 ty=$3; shift 3
  local IFS=,
  cat > "$T/$f" <<EOF
{"proposal":{"specs":[{"index":"$idx","imports":[],"api_collections":[
  {"collection_data":{"api_interface":"rest","type":"$ty"},"parse_directives":[],"apis":[$*]}]}]},"deposit":"x"}
EOF
}
# The script exits 1 on FAIL rows and this suite runs under `pipefail`, so a
# pipeline straight off it reports the expected failure as a test failure.
# Always capture with `|| true` first, then match.
failrows() { sed -n '/=== FAIL ===/,$p' <<<"$1"; }

# 1. curated write list at stateful 0 → FAIL
spec w0.json W0 "$(api author_submitAndWatchExtrinsic 0)"
if bash "$SCRIPT" "$T/w0.json" >/dev/null 2>&1; then fail "write-at-0: expected non-zero exit"; fi
OUT=$(bash "$SCRIPT" "$T/w0.json" 2>&1 || true)
failrows "$OUT" | grep -q "broadcasts a transaction" || fail "write-at-0: wrong message, got '$OUT'"
echo "write-at-0: OK"

# 2. same method at stateful 1 → PASS
spec w1.json W1 "$(api author_submitAndWatchExtrinsic 1)"
bash "$SCRIPT" "$T/w1.json" >/dev/null 2>&1 || fail "write-at-1: expected exit 0"
echo "write-at-1: OK"

# 3. curated read list at stateful 1 → FAIL (the cosmossdk shape)
spec r1.json R1 "$(api cosmos.tx.v1beta1.Service/Simulate 1)"
if bash "$SCRIPT" "$T/r1.json" >/dev/null 2>&1; then fail "read-at-1: expected non-zero exit"; fi
OUT=$(bash "$SCRIPT" "$T/r1.json" 2>&1 || true)
failrows "$OUT" | grep -q "changes nothing" || fail "read-at-1: wrong message, got '$OUT'"
echo "read-at-1: OK"

# 4. eth_fillTransaction — the trap SPEC_GUIDE/phase3.2 both call out
spec fill.json FILL "$(api eth_fillTransaction 1)"
if bash "$SCRIPT" "$T/fill.json" >/dev/null 2>&1; then fail "fillTransaction: expected non-zero exit"; fi
echo "fill-transaction-trap: OK"

# 5. REST verb disambiguation: POST /txs is BroadcastTx (must be 1),
#    GET on the same path is a query (must not be forced to 1).
restspec txpost.json TXPOST POST "$(api /cosmos/tx/v1beta1/txs 0)"
if bash "$SCRIPT" "$T/txpost.json" >/dev/null 2>&1; then fail "POST /txs at 0: expected non-zero exit"; fi
restspec txget.json TXGET GET "$(api /cosmos/tx/v1beta1/txs 0)"
bash "$SCRIPT" "$T/txget.json" >/dev/null 2>&1 || fail "GET /txs at 0 must pass"
echo "rest-verb-disambiguation: OK"

# 6. REST read at 1 → FAIL, and the same path under GET is not on the read list
restspec simpost.json SIMPOST POST "$(api /cosmos/tx/v1beta1/simulate 1)"
if bash "$SCRIPT" "$T/simpost.json" >/dev/null 2>&1; then fail "POST /simulate at 1: expected non-zero exit"; fi
echo "rest-read-at-1: OK"

# 7. an uncurated method is judged only by consensus, never FAIL.
#    Four siblings agree on 1; the candidate says 0 → INFO, exit 0.
for i in 1 2 3 4; do spec "sib$i.json" "SIB$i" "$(api some_custom_method 1)"; done
spec odd.json ODD "$(api some_custom_method 0)"
bash "$SCRIPT" "$T/odd.json" >/dev/null 2>&1 || fail "consensus must be advisory, not fatal"
OUT=$(bash "$SCRIPT" "$T/odd.json" 2>&1)
grep -q "use the opposite value" <<<"$OUT" || fail "consensus: expected an INFO row, got '$OUT'"
echo "consensus-advisory: OK"

# 8. below the 4-sibling threshold, consensus stays silent
rm -f "$T"/sib3.json "$T"/sib4.json
OUT=$(bash "$SCRIPT" "$T/odd.json" 2>&1)
grep -q "use the opposite value" <<<"$OUT" && fail "consensus fired below the sibling threshold"
echo "consensus-threshold: OK"

# 9. the dedupe key must keep the filename. A method declared twice inside ONE
#    spec counts once; the same method in two specs counts twice. Without the
#    filename in the sort -u key the whole catalogue collapses to one row per
#    value and consensus can never reach its threshold.
rm -f "$T"/*.json
for i in 1 2 3 4; do
  cat > "$T/dup$i.json" <<EOF
{"proposal":{"specs":[{"index":"DUP$i","imports":[],"api_collections":[
  {"collection_data":{"api_interface":"jsonrpc"},"parse_directives":[],"apis":[$(api dup_method 1)]},
  {"collection_data":{"api_interface":"rest","type":"GET"},"parse_directives":[],"apis":[$(api dup_method 1)]}]}]},"deposit":"x"}
EOF
done
spec dupodd.json DUPODD "$(api dup_method 0)"
OUT=$(bash "$SCRIPT" "$T/dupodd.json" 2>&1)
grep -q "use the opposite value" <<<"$OUT" || fail "dedupe key dropped the filename: consensus never reached threshold"
grep -qE "4/4 other specs" <<<"$OUT" || fail "dedupe counted collections instead of specs: '$(grep 'opposite value' <<<"$OUT")'"
echo "consensus-dedupe-key: OK"

# 10. a spec with no curated methods and no disagreement → clean pass
rm -f "$T"/*.json
spec clean.json CLEAN "$(api eth_blockNumber 0)"
bash "$SCRIPT" "$T/clean.json" >/dev/null 2>&1 || fail "clean: expected exit 0"
echo "clean-spec: OK"

echo "ALL TESTS PASSED"
