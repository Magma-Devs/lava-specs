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

while IFS=$'\t' read -r idx abt bdff bifp ablqs rt dre msp shares; do
  [[ -z "$idx" ]] && continue

  # Compute expected values (guard against abt<=0 to avoid div-by-zero)
  if [[ $abt -le 0 ]]; then
    EXP_BIFP=3
    EXP_ABLQS=1
  else
    EXP_BIFP=$(( (1000 + abt - 1) / abt ))
    [[ $EXP_BIFP -lt 3 ]] && EXP_BIFP=3
    EXP_ABLQS=$(( (10000 + abt - 1) / abt ))
    [[ $EXP_ABLQS -lt 1 ]] && EXP_ABLQS=1
  fi

  # Compare each field
  if [[ "$bifp" == "$EXP_BIFP" ]]; then
    PASS+=("blocks_in_finalization_proof|$idx|$bifp")
  else
    FAIL+=("blocks_in_finalization_proof|$idx|expected=$EXP_BIFP declared=$bifp")
  fi

  if [[ "$ablqs" == "$EXP_ABLQS" ]]; then
    PASS+=("allowed_block_lag_for_qos_sync|$idx|$ablqs")
  else
    FAIL+=("allowed_block_lag_for_qos_sync|$idx|expected=$EXP_ABLQS declared=$ablqs")
  fi

  if [[ "$rt" == "268435455" ]]; then
    PASS+=("reliability_threshold|$idx|$rt")
  else
    FAIL+=("reliability_threshold|$idx|expected=268435455 declared=$rt")
  fi

  if [[ "$dre" == "true" ]]; then
    PASS+=("data_reliability_enabled|$idx|true")
  else
    FAIL+=("data_reliability_enabled|$idx|expected=true declared=$dre")
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

  if [[ "$msp" == "true" ]]; then
    PASS+=("min_stake_provider|$idx|present")
  else
    FAIL+=("min_stake_provider|$idx|missing")
  fi

  if [[ -z "$shares" || "$shares" == "null" ]]; then
    FAIL+=("shares|$idx|missing")
  else
    PASS+=("shares|$idx|$shares")
  fi
done < <(jq -r '
  .proposal.specs[]
  | "\(.index)\t\(.average_block_time // 0)\t\(.block_distance_for_finalized_data // "null")\t\(.blocks_in_finalization_proof // "null")\t\(.allowed_block_lag_for_qos_sync // "null")\t\(.reliability_threshold // "null")\t\(if .data_reliability_enabled == null then "null" else (.data_reliability_enabled | tostring) end)\t\(.min_stake_provider != null)\t\(.shares // "null")"
' "$SPEC")

echo "=== PASS ==="
printf '%s\n' "${PASS[@]}"
echo
echo "=== FAIL ==="
printf '%s\n' "${FAIL[@]}"

[[ ${#FAIL[@]} -eq 0 ]] || exit 1
