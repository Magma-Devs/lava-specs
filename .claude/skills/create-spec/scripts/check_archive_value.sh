#!/usr/bin/env bash
# check_archive_value.sh — archive-tier pruning expected_value must be
# router-parseable. The router does strconv.ParseInt(value,10,64) ONLY on the
# GET_BLOCK_BY_NUM path without a latest_distance (chain_fetcher.go:314-337).
# FAIL exactly that combination when expected_value is not a base-10 integer
# (e.g. "*"). Every other path (latest_distance set, or function_tag none /
# GET_EARLIEST_BLOCK / VERIFICATION) is fine and is not flagged.
set -euo pipefail
export LC_ALL=C

[[ $# -eq 1 ]] || { echo "usage: $0 <spec.json>" >&2; exit 2; }
SPEC=$(realpath -- "$1")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

FAIL=(); PASS=()
while IFS=$'\t' read -r idx iface ft ld ev; do
  [[ -z "$idx" ]] && continue
  if [[ "$ft" == "GET_BLOCK_BY_NUM" && ( "$ld" == "0" || "$ld" == "null" || -z "$ld" ) ]]; then
    if [[ "$ev" =~ ^[0-9]+$ ]]; then
      PASS+=("$idx|$iface|archive ev=$ev (integer on GET_BLOCK_BY_NUM path)")
    else
      FAIL+=("$idx|$iface|archive pruning expected_value=\"$ev\" is not a base-10 integer on the GET_BLOCK_BY_NUM path -> router ParseInt fails and excludes the archive provider at boot. Use \"1\" or set latest_distance.")
    fi
  else
    PASS+=("$idx|$iface|archive ev=\"$ev\" ft=$ft ld=$ld (non-ParseInt path)")
  fi
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.verifications[]? | select(.name=="pruning")
  | (.parse_directive.function_tag // "none") as $ft
  | .values[]? | select(.extension=="archive")
  | "\($s.index)\t\($c.collection_data.api_interface)\t\($ft)\t\(.latest_distance // 0)\t\(.expected_value // "")"
' "$SPEC")

echo "=== PASS ==="; printf '%s\n' "${PASS[@]:-}"
echo; echo "=== FAIL ==="; printf '%s\n' "${FAIL[@]:-}"
echo
if [[ ${#FAIL[@]} -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
