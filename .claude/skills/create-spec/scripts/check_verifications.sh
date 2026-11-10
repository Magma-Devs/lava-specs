#!/usr/bin/env bash
# check_verifications.sh — verify schema + expected_value for every verifications[] entry.
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
INFO=()

# Extract: idx | collection_iface | ver_name | has_parse_directive | pd_function_tag | num_values | first_expected_value
# Note: parse_directive is optional; absent means the chain validator assigns DISABLED tag (zero value).
while IFS=$'\t' read -r idx iface name has_pd pd_tag nvals val0; do
  [[ -z "$idx" ]] && continue
  ROW="$idx/$iface/$name"

  # Required fields
  if [[ "$name" == "null" || -z "$name" ]]; then
    FAIL+=("$ROW|missing name"); continue
  fi
  if [[ "$nvals" == "0" || "$nvals" == "null" ]]; then
    FAIL+=("$ROW|missing values[]")
  else
    # expected_value check
    if [[ -z "$val0" || "$val0" == "null" ]]; then
      INFO+=("$ROW|values[0].expected_value missing (latest_distance-only check)")
    elif [[ "$val0" == "*" ]]; then
      INFO+=("$ROW|values[0].expected_value is wildcard '*'")
    else
      PASS+=("$ROW|expected_value=$val0")
    fi
  fi

done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.verifications[]?
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.name // "null")\t\(.parse_directive != null)\t\(.parse_directive.function_tag // "null")\t\(.values | length)\t\(if (.values[0].expected_value? // null) == null or (.values[0].expected_value? // null) == "" then "null" else .values[0].expected_value end)"
' "$SPEC")

# Severity, on every value: it lives on values[], not on the verification (proto
# ParseValue.severity), and each value is its own check. It says what the check's
# failure costs (MAG-3950): Fail takes the url out, PartialFail switches off only the
# add-on or extension the check covers, Warning nothing. A value that sets none takes the
# default for where its check sits: Fail for a basic check (a collection with no add_on,
# a value with no extension), PartialFail for an add-on or extension check.
# Extract: idx | collection_iface | ver_name | value_index | add_on ("-" for none) | extension ("-" for none) | severity
while IFS=$'\t' read -r idx iface name i addon ext sev; do
  [[ -z "$idx" ]] && continue
  ROW="$idx/$iface/$name"
  [[ "$addon" == "-" ]] && addon=""
  [[ "$ext" == "-" ]] && ext=""
  where="values[$i]"
  [[ -n "$addon" ]] && where="$where add-on $addon"
  [[ -n "$ext" ]] && where="$where extension $ext"
  # The router charges an add-on check to its extension first, else to its add-on.
  part="${ext:-$addon}"
  case "$sev" in
    null|"")
      if [[ -z "$part" ]]; then
        PASS+=("$ROW|$where severity=Fail (default for a basic check)")
      else
        PASS+=("$ROW|$where severity=PartialFail (default for an add-on or extension check)")
      fi ;;
    Warning) PASS+=("$ROW|$where severity=Warning") ;;
    Fail)
      PASS+=("$ROW|$where severity=Fail")
      if [[ -n "$part" ]]; then
        INFO+=("$ROW|$where severity=Fail makes $part mandatory: on a router with MAG-3950 its failure takes the url out, not only $part")
      fi ;;
    PartialFail)
      if [[ -z "$part" ]]; then
        FAIL+=("$ROW|$where severity=PartialFail on a basic check: there is no smaller part to switch off, and the router reads it as Fail; set Fail, or leave it out")
      else
        PASS+=("$ROW|$where severity=PartialFail")
      fi ;;
    *) FAIL+=("$ROW|$where severity invalid ($sev), expected Warning|Fail|PartialFail") ;;
  esac
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.verifications[]? as $v
  | ($v.values // []) | to_entries[]
  | "\($s.index)\t\($c.collection_data.api_interface)\t\($v.name // "null")\t\(.key)\t\(if ($c.collection_data.add_on // "") == "" then "-" else $c.collection_data.add_on end)\t\(if (.value.extension // "") == "" then "-" else .value.extension end)\t\(.value.severity // "null")"
' "$SPEC")

# Cross-reference: every verification's parse_directive.function_tag must exist in its own collection's parse_directives[]
# Single jq call: emit one row per (idx, iface, name, pd_tag, found) — `found` is computed within jq using `any`.
while IFS=$'\t' read -r idx iface name pd_tag found; do
  [[ -z "$idx" ]] && continue
  ROW="$idx/$iface/$name"
  if [[ "$found" == "true" ]]; then
    PASS+=("$ROW|parse_directive ref ($pd_tag) found in collection")
  else
    FAIL+=("$ROW|parse_directive ref ($pd_tag) NOT found in collection")
  fi
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.verifications[]?
  | select(.parse_directive != null)
  | select(.parse_directive.function_tag != "VERIFICATION")
  | .parse_directive.function_tag as $tag
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.name)\t\($tag)\t\([$c.parse_directives[]?.function_tag] | any(. == $tag))"
' "$SPEC")

echo "=== PASS ==="
printf '%s\n' ${PASS[@]+"${PASS[@]}"}
echo
echo "=== FAIL ==="
printf '%s\n' ${FAIL[@]+"${FAIL[@]}"}
echo
echo "=== INFO ==="
printf '%s\n' ${INFO[@]+"${INFO[@]}"}

[[ ${#FAIL[@]} -eq 0 ]] || exit 1
