#!/usr/bin/env bash
# check_extensions.sh — verify extensions schema + addon↔verification correspondence.
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

# Per-extension schema check
while IFS=$'\t' read -r idx iface ext_name has_cu cu rule_block; do
  [[ -z "$idx" ]] && continue
  ROW="$idx/$iface/$ext_name"

  if [[ "$ext_name" == "null" || -z "$ext_name" ]]; then
    FAIL+=("$ROW|extension missing name"); continue
  fi

  if [[ "$has_cu" != "true" ]]; then
    FAIL+=("$ROW|missing cu_multiplier")
  elif [[ -z "$cu" || "$cu" == "null" ]]; then
    FAIL+=("$ROW|cu_multiplier is null")
  else
    PASS+=("$ROW|cu_multiplier=$cu")
  fi

  if [[ "$ext_name" == "archive" ]]; then
    if [[ -z "$rule_block" || "$rule_block" == "null" ]]; then
      FAIL+=("$ROW|archive extension missing rule.block")
    else
      PASS+=("$ROW|rule.block=$rule_block")
    fi
  fi

done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.extensions[]?
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.name // "null")\t\(.cu_multiplier != null)\t\(.cu_multiplier // "null")\t\(.rule.block // "null")"
' "$SPEC")

# Addon ↔ verification correspondence
while IFS=$'\t' read -r idx iface addon nvers; do
  [[ -z "$idx" || -z "$addon" || "$addon" == "" ]] && continue
  ROW="$idx/$iface/add_on:$addon"
  if [[ "$nvers" == "0" || "$nvers" == "null" ]]; then
    FAIL+=("$ROW|addon collection has no verifications")
  else
    PASS+=("$ROW|verifications=$nvers")
  fi
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]
  | select((.collection_data.add_on // "") != "")
  | "\($s.index)\t\(.collection_data.api_interface)\t\(.collection_data.add_on)\t\(.verifications | length)"
' "$SPEC")

# Duplicate extension names per collection
while IFS=$'\t' read -r idx iface dup; do
  [[ -z "$dup" || "$dup" == "null" ]] && continue
  FAIL+=("$idx/$iface|duplicate extension name: $dup")
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]
  | "\($s.index)\t\(.collection_data.api_interface)\t\(([.extensions[]?.name] | group_by(.) | map(select(length>1) | .[0])) | join(","))"
' "$SPEC" | awk -F'\t' '$3 != ""')

echo "=== PASS ==="
printf '%s\n' "${PASS[@]}"
echo
echo "=== FAIL ==="
printf '%s\n' "${FAIL[@]}"

[[ ${#FAIL[@]} -eq 0 ]] || exit 1
