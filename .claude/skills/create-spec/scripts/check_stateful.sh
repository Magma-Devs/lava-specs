#!/usr/bin/env bash
# check_stateful.sh — direction check for `category.stateful`.
#
# `stateful: 1` is not a label, it is a routing instruction. It maps to
# common.CONSISTENCY_SELECT_ALL_PROVIDERS, and the router acts on it in four
# places (rpcsmartrouter_server.go:3336, :3585, :3835, :4735): the call is fanned
# out to EVERY provider, and it is excluded from cross-validation
# (cross_validation_policy.go:422) and from the recovery probe
# (recovery_probe.go:112-133).
#
# So the two directions fail differently, and both silently:
#   stateful: 0 on a write  -> the broadcast goes to ONE provider. No
#                              multi-provider redundancy on the path where it
#                              matters most. (avt/bsx, MAG-3389.)
#
#     Scope caveat, verified: the per-relay effects above are UNARY-ONLY. Like
#     GetRelayTimeout, GetStateful is unreachable from the subscription path --
#     it appears in rpcsmartrouter_server.go, recovery_probe.go,
#     unified_relay_state_machine.go and common.go, and in none of the
#     subscription managers. So on a SUBSCRIBE-tagged method such as
#     author_submitAndWatchExtrinsic, provider fan-out does NOT depend on this
#     flag. What does still read it there is ApiHasStatefulCategory
#     (base_chain_parser.go:549, via rpcsmartrouter_server.go:456): a lookup by
#     method NAME, transport-independent, used by the cross-validation policy
#     guard to reject an enabled per-method CV policy on a write. That is why
#     the write list still FAILs on subscription methods rather than skipping
#     them the way check_hanging_api.sh rule 1 does -- hanging_api has no
#     equivalent name-keyed reader.
#   stateful: 1 on a read   -> every read is fanned out to all providers, billed
#                              accordingly, and loses cross-validation.
#                              (cosmossdk's simulate/encode/decode, MAG-3389.)
#
# Unlike hanging_api, this cannot be settled from the router source: "does this
# method change chain state" is chain knowledge. Nor can it be settled by vote —
# across the catalogue `author_submitAndWatchExtrinsic` splits 10 specs at 0
# against 11 at 1, with kusama.json and polkadot.json on opposite sides, so a
# majority rule produces no answer exactly where one is needed.
#
# Hence three checks of decreasing confidence:
#
#   1. WRITE list  (FAIL) — methods that unambiguously broadcast. Curated, not
#      voted, so it still fires when the whole catalogue agrees and is wrong.
#   2. READ list   (FAIL) — simulation and codec helpers that change nothing.
#      SPEC_GUIDE.md and phase3.2 both name eth_fillTransaction as the classic
#      trap: a *_fill*/*_prepare* helper whose argument shape looks like a tx.
#   3. Consensus   (INFO) — where >= 90% of sibling specs declaring a name agree
#      and the candidate differs. Advisory only: 24 of 5,539 distinct method
#      names in the catalogue genuinely disagree, so this is a prompt to look,
#      never a verdict.
#
# REST entries are keyed "TYPE /path" where the HTTP verb disambiguates, because
# GET /cosmos/tx/v1beta1/txs is a query and POST to the same path is BroadcastTx.
# Using the verb as a proxy for "is a write" is itself the bug that put four read
# endpoints on the write path in cosmossdk.json — the verb disambiguates a name
# collision here, it does not classify.
#
# Usage: check_stateful.sh <spec.json>
# Prints "=== PASS ===" / "=== INFO ===" / "=== FAIL ==="; exit 1 on any FAIL row.

set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <spec.json>" >&2
  exit 2
fi
SPEC=$(realpath -- "$1")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }
SPECDIR=$(dirname "$SPEC")

# ---- Curated ground truth. Entries with a space are "TYPE name" (REST verb).
# Broadcast a signed transaction to the network.
WRITE_METHODS=(
  # Substrate
  author_submitExtrinsic
  author_submitAndWatchExtrinsic
  transaction_v1_broadcast
  transactionWatch_v1_submitAndWatch
  # EVM
  eth_sendRawTransaction
  eth_sendTransaction
  eth_sendRawTransactionSync
  # Cosmos / Tendermint
  cosmos.tx.v1beta1.Service/BroadcastTx
  "POST /cosmos/tx/v1beta1/txs"
  broadcast_tx_sync
  broadcast_tx_async
  broadcast_tx_commit
  # Solana
  sendTransaction
  # Starknet
  starknet_addInvokeTransaction
  starknet_addDeclareTransaction
  starknet_addDeployAccountTransaction
)

# Simulate, estimate, encode or decode. No submission, no state change.
READ_METHODS=(
  # EVM — phase3.2:  eth_call/eth_estimateGas/eth_simulateV1 pure simulation,
  # debug_traceCall trace-only, eth_fillTransaction populates and returns.
  eth_call
  eth_estimateGas
  eth_simulateV1
  debug_traceCall
  eth_fillTransaction
  # Cosmos gRPC
  cosmos.tx.v1beta1.Service/Simulate
  cosmos.tx.v1beta1.Service/TxEncode
  cosmos.tx.v1beta1.Service/TxDecode
  cosmos.tx.v1beta1.Service/TxEncodeAmino
  cosmos.tx.v1beta1.Service/TxDecodeAmino
  # Cosmos REST — the counterparts of the gRPC entries above
  "POST /cosmos/tx/v1beta1/simulate"
  "POST /cosmos/tx/v1beta1/encode"
  "POST /cosmos/tx/v1beta1/decode"
  "POST /cosmos/tx/v1beta1/encode/amino"
  "POST /cosmos/tx/v1beta1/decode/amino"
)

in_list() { # needle, then list elements
  local n=$1; shift
  local e
  for e in "$@"; do [[ "$e" == "$n" ]] && return 0; done
  return 1
}

# ---- Consensus map over sibling specs: "name<TAB>stateful" -> count.
# Keyed on bare name (not verb-qualified): consensus is advisory, and the extra
# precision is not worth 140 more jq passes.
declare -A AGREE
declare -A TOTAL
# The candidate is excluded: the verdict is phrased as "N/M OTHER specs", and
# counting the candidate's own value in the denominator both misstates that and
# drags the ratio below the threshold (4 siblings agreeing is 4/4, not 4/5).
# Basename comparison, not realpath: the glob and the candidate are already in
# the same directory, and a realpath subprocess per sibling costs ~140 forks per
# invocation for nothing.
SPECBASE=${SPEC##*/}
shopt -s nullglob
SIBS=()
for _s in "$SPECDIR"/*.json; do
  [[ "${_s##*/}" == "$SPECBASE" ]] && continue
  SIBS+=("$_s")
done
shopt -u nullglob
if ((${#SIBS[@]})); then
  # The filename must survive into the dedupe key: a spec may declare the same
  # method in several collections (jsonrpc + rest), which should count once, but
  # two different specs declaring it must count twice. Dropping the filename
  # before `sort -u` collapses the whole catalogue to one row per distinct value
  # and the consensus test can then never reach its threshold.
  while IFS=$'\t' read -r _f nm st; do
    [[ -z "$nm" ]] && continue
    AGREE["$nm|$st"]=$(( ${AGREE["$nm|$st"]:-0} + 1 ))
    TOTAL["$nm"]=$(( ${TOTAL["$nm"]:-0} + 1 ))
  done < <(jq -r 'input_filename as $f
      | .proposal.specs[]?.api_collections[]?.apis[]?
      | select(.name) | [$f, .name, ((.category.stateful // 0)|tostring)] | @tsv' \
      "${SIBS[@]}" 2>/dev/null | sort -u)
fi

PASS=(); FAIL=(); INFO=()

while IFS=$'\t' read -r idx iface ctype name st; do
  [[ -z "$name" || "$name" == "null" ]] && continue
  ROW="$idx/$iface/$name"
  KEY="$name"
  if [[ "$iface" == "rest" ]]; then
    if [[ -n "$ctype" && "$ctype" != "-" ]]; then
      KEY="$ctype $name"
    else
      # No verb to key on, so a curated REST entry cannot match and the row would
      # skip both lists in silence. Every rest collection in the catalogue
      # currently carries a type; say so out loud if one ever does not.
      INFO+=("$ROW|rest collection has no collection_data.type, so verb-keyed write/read rules cannot be applied to it — check this method's stateful by hand")
    fi
  fi

  # 1. curated write list
  if in_list "$KEY" "${WRITE_METHODS[@]}" || in_list "$name" "${WRITE_METHODS[@]}"; then
    if [[ "$st" != "1" ]]; then
      FAIL+=("$ROW|broadcasts a transaction but stateful=${st}; must be 1 — it gates write routing on the unary path (GetSessions / CONSISTENCY_SELECT_ALL_PROVIDERS) and the cross-validation policy guard (ApiHasStatefulCategory), a name lookup that applies on every transport including subscriptions")
    else
      PASS+=("$ROW|write, stateful=1")
    fi
    continue
  fi

  # 2. curated read list
  if in_list "$KEY" "${READ_METHODS[@]}" || in_list "$name" "${READ_METHODS[@]}"; then
    if [[ "$st" == "1" ]]; then
      FAIL+=("$ROW|simulation/codec helper with stateful=1; it changes nothing, so this fans every call out to all providers and drops cross-validation — set 0")
    else
      PASS+=("$ROW|read, stateful=${st}")
    fi
    continue
  fi

  # 3. consensus, advisory
  total=${TOTAL["$name"]:-0}
  other=$(( total - ${AGREE["$name|$st"]:-0} ))
  if (( total >= 4 && other * 10 >= total * 9 )); then
    INFO+=("$ROW|stateful=${st} but ${other}/${total} other specs declaring this method use the opposite value — verify against the chain's docs")
  fi
done < <(jq -r '
  .proposal.specs[]? as $s
  | $s.api_collections[]? as $c
  | $c.apis[]?
  | [ $s.index,
      ($c.collection_data.api_interface // "?"),
      ($c.collection_data.type // "-"),
      .name,
      ((.category.stateful // 0)|tostring)
    ] | @tsv' "$SPEC")

echo "=== PASS ==="
((${#PASS[@]})) && printf '%s\n' "${PASS[@]}"
echo
echo "=== INFO ==="
((${#INFO[@]})) && printf '%s\n' "${INFO[@]}"
echo
echo "=== FAIL ==="
((${#FAIL[@]})) && printf '%s\n' "${FAIL[@]}"

((${#FAIL[@]})) && exit 1
exit 0
