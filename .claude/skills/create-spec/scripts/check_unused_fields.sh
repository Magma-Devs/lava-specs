#!/usr/bin/env bash
# check_unused_fields.sh — reintroduction guard for the spec field-level cleanup.
#
# Fails if a spec JSON contains any of the 15 fields that were removed from the
# smart-router model (Magma-Devs/smart-router#218). Reports the exact JSON path
# of every occurrence so a human can locate it.
#
# Usage:
#   check_unused_fields.sh <spec.json> [more.json ...]          # strict (default)
#   check_unused_fields.sh --warn <spec.json> [more.json ...]   # warning mode
#
# Strict mode (CI, creation, review, evaluation): exit 1 if any removed field is
# present. Warning mode (deliberately testing a legacy compatibility fixture):
# report the findings but exit 0 so the legacy file can still be exercised.
set -euo pipefail

WARN=0
if [[ "${1:-}" == "--warn" ]]; then WARN=1; shift; fi
if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--warn] <spec.json> [more.json ...]" >&2
  exit 2
fi

# The 15 removed keys. Names are unique to their nesting level across the
# catalog (no collisions), so matching by key name is sufficient; the reported
# path gives full context regardless.
TARGETS='["min_stake_provider","providers_types","contributor","contributor_percentage","shares","identity","block_last_updated","reliability_threshold","data_reliability_enabled","title","description","deposit","extra_compute_units","local","subscription"]'

count=0
for f in "$@"; do
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    echo "REMOVED_FIELD | $f | $path"
    count=$((count + 1))
  done < <(jq -r --argjson t "$TARGETS" '
      [ paths as $p
        | select(($p[-1] | type == "string") and ($p[-1] | IN($t[])))
        | $p | map(tostring) | join(".") ]
      | .[]
    ' "$f")
done

if [[ "$count" -gt 0 ]]; then
  if [[ "$WARN" == 1 ]]; then
    echo "RESULT: PASS (warn mode — $count removed field(s) reported, not blocking)"
    exit 0
  fi
  echo "RESULT: FAIL ($count removed field(s) present)"
  exit 1
fi
echo "RESULT: PASS (no removed fields)"
exit 0