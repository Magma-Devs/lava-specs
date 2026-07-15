#!/usr/bin/env bash
# check_pruning.sh — verify archive rule.block + pruning latest_distance against
# research-derived retention window (in blocks). >3x off in either direction = FAIL.
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <spec.json> <retention_blocks|unknown>" >&2
  exit 2
fi
SPEC=$(realpath -- "$1")
RET="$2"
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

if [[ "$RET" == "unknown" ]]; then
  echo "INFO: retention unknown — pruning values not verifiable, skipping"
  echo "RESULT: PASS"
  exit 0
fi
if ! [[ "$RET" =~ ^[0-9]+$ ]] || [[ "$RET" -le 0 ]]; then
  echo "usage: retention_blocks must be a positive integer or 'unknown' (got: $RET)" >&2
  exit 2
fi

LOW=$(( RET / 3 ))           # 3x smaller bound
HIGH=$(( RET * 3 ))          # 3x larger bound
FAIL=()
PASS=()

# Emit: idx <TAB> field <TAB> value, one per archive rule.block and pruning latest_distance
while IFS=$'\t' read -r idx field val; do
  [[ -z "$idx" ]] && continue
  if [[ "$val" == "null" || -z "$val" ]]; then continue; fi
  if (( val < LOW || val > HIGH )); then
    FAIL+=("$field|$idx|expected≈$RET (band $LOW–$HIGH) declared=$val")
  else
    PASS+=("$field|$idx|$val")
  fi
done < <(jq -r '
  .proposal.specs[] as $s
  | ( $s.api_collections[]?.extensions[]? | select(.name=="archive") | "\($s.index)\trule.block\t\(.rule.block)" ),
    ( $s.api_collections[]?.verifications[]? | select(.name=="pruning") | .values[]? | select(.latest_distance != null) | "\($s.index)\tlatest_distance\t\(.latest_distance)" )
' "$SPEC")

echo "=== PASS ==="
printf '%s\n' "${PASS[@]:-}"
echo
echo "=== FAIL ==="
printf '%s\n' "${FAIL[@]:-}"
echo
if [[ ${#FAIL[@]} -eq 0 ]]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
