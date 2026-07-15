#!/usr/bin/env bash
# check_method_schema.sh — per-method required fields + parser_arg shape + no duplicates per collection.
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

# Required-field check
while IFS=$'\t' read -r idx iface name has_en has_cu has_bp has_cat has_pfunc has_parg parg_kind; do
  [[ -z "$idx" || -z "$name" || "$name" == "null" ]] && continue
  ROW="$idx/$iface/$name"

  [[ "$has_en"  == "true" ]] || FAIL+=("$ROW|missing enabled")
  [[ "$has_cu"  == "true" ]] || FAIL+=("$ROW|missing compute_units")
  [[ "$has_bp"  == "true" ]] || FAIL+=("$ROW|missing block_parsing")
  [[ "$has_cat" == "true" ]] || FAIL+=("$ROW|missing category")

  if [[ "$has_bp" == "true" ]]; then
    [[ "$has_pfunc" == "true" ]] || FAIL+=("$ROW|missing block_parsing.parser_func")
    [[ "$has_parg"  == "true" ]] || FAIL+=("$ROW|missing block_parsing.parser_arg")
    if [[ "$has_parg" == "true" && "$parg_kind" != "all_strings" ]]; then
      FAIL+=("$ROW|block_parsing.parser_arg contains non-string element ($parg_kind)")
    fi
  fi

  [[ ${#FAIL[@]} -gt 0 && "${FAIL[-1]}" == "$ROW|"* ]] || PASS+=("$ROW|schema ok")
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.apis[]?
  | (.block_parsing.parser_arg // []) as $parg
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.name // "null")\t\(.enabled != null)\t\(.compute_units != null)\t\(.block_parsing != null)\t\(.category != null)\t\(.block_parsing.parser_func != null)\t\(.block_parsing.parser_arg != null)\t\(if ($parg | all(type == "string")) then "all_strings" else ($parg | map(type) | unique | join(",")) end)"
' "$SPEC")

# Duplicates per collection
while IFS=$'\t' read -r idx iface dup; do
  [[ -z "$dup" ]] && continue
  FAIL+=("$idx/$iface|duplicate api name: $dup")
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]
  | [.apis[]?.name] as $names
  | ($names | group_by(.) | map(select(length>1) | .[0])) as $dups
  | $dups[]
  | "\($s.index)\t\($c // "")\t\(.)"
' "$SPEC" 2>/dev/null || true)

# Fallback duplicates check (simpler jq)
DUPS=$(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[] as $c
  | $c.apis as $apis
  | ($apis | map(.name) | group_by(.) | map(select(length>1) | .[0])) as $dups
  | $dups[]
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.)"
' "$SPEC")

while IFS=$'\t' read -r idx iface name; do
  [[ -z "$name" ]] && continue
  FAIL+=("$idx/$iface|duplicate api name: $name")
done <<< "$DUPS"

echo "=== PASS ==="
printf '%s\n' "${PASS[@]}"
echo
echo "=== FAIL ==="
printf '%s\n' "${FAIL[@]}"

[[ ${#FAIL[@]} -eq 0 ]] || exit 1
