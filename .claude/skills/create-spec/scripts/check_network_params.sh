#!/usr/bin/env bash
# check_network_params.sh — verify formula-derived network params per spec entry.
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <spec.json>" >&2
  exit 2
fi
SPEC=$(realpath -- "$1")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

PASS=()
FAIL=()

while IFS=$'\t' read -r idx abt bdff bifp ablqs; do
  [[ -z "$idx" ]] && continue

  # Compute expected values (guard against abt<=0 to avoid div-by-zero)
  if [[ $abt -le 0 ]]; then
    BIFP_FALLBACK=3
    EXP_ABLQS=1
  else
    BIFP_FALLBACK=$(( (1000 + abt - 1) / abt ))
    [[ $BIFP_FALLBACK -lt 3 ]] && BIFP_FALLBACK=3
    EXP_ABLQS=$(( (10000 + abt - 1) / abt ))
    [[ $EXP_ABLQS -lt 1 ]] && EXP_ABLQS=1
  fi

  # blocks_in_finalization_proof is FINALITY-TYPED, not a single formula (SKILL.md):
  #   1                      -> fast/instant finality (BFT/Tendermint/Cosmos/Solana/instant-L2)
  #   3                      -> probabilistic finality (PoW/slow PoS)
  #   max(ceil(1000/abt),3)  -> fallback only when the finality model is unclassifiable
  # The gate can't know the finality class (it isn't stored in the spec), so it accepts
  # any formula-legal value {1, 3, fallback} and only rejects off-formula numbers (0,2,5,…).
  # Pinning the fallback as the sole expected value wrongly forced instant-finality chains
  # (Akash, Algorand) to 3 and overrode synthesis's correct 1 (see Lumia PR #10).
  if [[ "$bifp" == "1" || "$bifp" == "3" || "$bifp" == "$BIFP_FALLBACK" ]]; then
    PASS+=("blocks_in_finalization_proof|$idx|$bifp")
  else
    FAIL+=("blocks_in_finalization_proof|$idx|declared=$bifp not in legal set {1,3,$BIFP_FALLBACK}")
  fi

  if [[ "$ablqs" == "$EXP_ABLQS" ]]; then
    PASS+=("allowed_block_lag_for_qos_sync|$idx|$ablqs")
  else
    FAIL+=("allowed_block_lag_for_qos_sync|$idx|expected=$EXP_ABLQS declared=$ablqs")
  fi

  if [[ -z "$abt" || "$abt" == "null" || "$abt" == "0" ]]; then
    FAIL+=("average_block_time|$idx|missing or zero")
  else
    PASS+=("average_block_time|$idx|$abt")
  fi

  if [[ -z "$bdff" || "$bdff" == "null" ]]; then
    FAIL+=("block_distance_for_finalized_data|$idx|missing")
  else
    PASS+=("block_distance_for_finalized_data|$idx|$bdff")
  fi
done < <(jq -r '
  .proposal.specs[]
  | "\(.index)\t\(.average_block_time // 0)\t\(.block_distance_for_finalized_data // "null")\t\(.blocks_in_finalization_proof // "null")\t\(.allowed_block_lag_for_qos_sync // "null")"
' "$SPEC")

echo "=== PASS ==="
printf '%s\n' ${PASS[@]+"${PASS[@]}"}
echo
echo "=== FAIL ==="
printf '%s\n' ${FAIL[@]+"${FAIL[@]}"}

[[ ${#FAIL[@]} -eq 0 ]] || exit 1
