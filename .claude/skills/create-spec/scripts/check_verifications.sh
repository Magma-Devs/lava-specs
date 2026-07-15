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

# Extract: idx | collection_iface | ver_name | has_parse_directive | pd_function_tag | num_values | first_expected_value | severity
# Note: severity lives on values[], not on the verification itself (proto ParseValue.severity).
# Note: parse_directive is optional; absent means the chain validator assigns DISABLED tag (zero value).
while IFS=$'\t' read -r idx iface name has_pd pd_tag nvals val0 sev; do
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

  # severity enum (per proto, severity lives on values[] and defaults to Fail when absent)
  case "$sev" in
    Warning|Fail|Stop) PASS+=("$ROW|severity=$sev") ;;
    null|"") PASS+=("$ROW|severity=Fail (default)") ;;
    *) FAIL+=("$ROW|severity invalid ($sev), expected Warning|Fail|Stop") ;;
  esac

done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.verifications[]?
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.name // "null")\t\(.parse_directive != null)\t\(.parse_directive.function_tag // "null")\t\(.values | length)\t\(if (.values[0].expected_value? // null) == null or (.values[0].expected_value? // null) == "" then "null" else .values[0].expected_value end)\t\(.values[0].severity // "null")"
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
