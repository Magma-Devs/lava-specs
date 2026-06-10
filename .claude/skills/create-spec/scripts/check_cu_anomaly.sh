#!/usr/bin/env bash
# check_cu_anomaly.sh — flag suspiciously-uniform compute_units per spec entry.
# FAIL if (M>15 AND distinct<3) OR (M>=10 AND max single-value share >70%).
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <spec.json>" >&2
  exit 2
fi
SPEC=$(realpath -- "$1")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

FAIL=()
PASS=()

# Per index: M (count) <TAB> D (distinct) <TAB> MAXC (largest group)
while IFS=$'\t' read -r idx m d maxc; do
  [[ -z "$idx" ]] && continue
  reason=""
  if (( m > 15 && d < 3 )); then
    reason="only $d distinct CU values across $m methods"
  fi
  if (( m >= 10 )); then
    share=$(( maxc * 100 / m ))
    if (( share > 70 )); then
      [[ -n "$reason" ]] && reason="$reason; "
      reason="${reason}${share}% of $m methods share one CU value"
    fi
  fi
  if [[ -n "$reason" ]]; then
    FAIL+=("$idx|$reason")
  else
    PASS+=("$idx|M=$m D=$d")
  fi
done < <(jq -r '
  .proposal.specs[]
  | .index as $idx
  | [ .api_collections[]?.apis[]?.compute_units ] as $cu
  | ($cu | length) as $m
  | ($cu | group_by(.) | map(length)) as $g
  | "\($idx)\t\($m)\t\($g | length)\t\($g | max // 0)"
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
