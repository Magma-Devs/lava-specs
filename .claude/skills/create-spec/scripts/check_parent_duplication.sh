#!/usr/bin/env bash
# check_parent_duplication.sh — catch a spec that hand-rolls a base spec's method
# set instead of inheriting it.
#
# Usage:
#   check_parent_duplication.sh <spec.json> [--threshold N] [--allow FILE] [--min-fanin K]
#
# Deliberate exceptions live in a reviewable ledger, not in the script. Each
# line of the allow file is "<INDEX> <REDUNDANT|UNIMPORTED> <token> # why",
# where <token> is the method name (REDUNDANT) or the base index (UNIMPORTED).
# Defaults to spec-inheritance-exceptions.txt beside the specs (repo root).
#
# Two failures, both of which shipped undetected:
#
#   REDUNDANT — the spec imports a parent and then re-declares a method the
#   parent already defines in the SAME collection (same api_interface /
#   internal_path / type / add_on) with a BYTE-IDENTICAL definition: dead weight
#   that pretends to be a decision. A re-declaration that actually changes
#   something (compute_units, category.deterministic, block_parsing) is a
#   deliberate override — MOONRIVER prices debug_traceBlockByNumber at 200 CU and
#   parses debug_traceTransaction by params[0] — and is NOT flagged, because
#   nothing in the file distinguishes chain-specific tuning from drift. Neither is
#   an "enabled": false re-declaration, the documented positive-evidence disable.
#
#   UNIMPORTED — the spec declares >= N methods that a base spec in this repo
#   owns, but its import closure never reaches that base. This is what shipped
#   in TRAC/HYDRATION/BITTENSOR/LIT: 47 ETH1 methods copied by hand into an
#   "evm" add-on, 14 of them already drifted from ETH1's block_parsing/CU.
#   Fix by importing the base — or, if the chain genuinely serves that RPC on a
#   DIFFERENT host (probe it: does the endpoint answer both surfaces?), keep the
#   add-on and record the probe in the PR body. ACA is the legitimate case: its
#   Substrate RPC answers -32601 for eth_chainId.
#
# Parents are resolved by CONTENT, not filename (ETH1 lives in ethereum.json),
# the same way compare_spec_methods.sh does it.
set -euo pipefail
export LC_ALL=C

THRESHOLD=10
SPEC=""
ALLOW=""
MIN_FANIN=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD=${2:-}; shift 2 ;;
    --allow) ALLOW=${2:-}; shift 2 ;;
    --min-fanin) MIN_FANIN=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) [[ -z "$SPEC" ]] || { echo "usage: $0 <spec.json> [--threshold N]" >&2; exit 2; }; SPEC=$1; shift ;;
  esac
done
[[ -n "$SPEC" ]] || { echo "usage: $0 <spec.json> [--threshold N]" >&2; exit 2; }
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || { echo "usage: --threshold takes a non-negative integer (got: $THRESHOLD)" >&2; exit 2; }
[[ "$MIN_FANIN" =~ ^[0-9]+$ ]] || { echo "usage: --min-fanin takes a non-negative integer (got: $MIN_FANIN)" >&2; exit 2; }
SPEC=$(realpath -- "$SPEC")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }
DIR=$(dirname "$SPEC")
[[ -n "$ALLOW" ]] || ALLOW="$DIR/spec-inheritance-exceptions.txt"

# ALLOWED["<INDEX> <RULE> <token>"]=reason
declare -A ALLOWED=()
if [[ -r "$ALLOW" ]]; then
  while IFS= read -r line; do
    line=${line%%$'\r'}
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    why=${line#*#}; rule=${line%%#*}
    read -r a_idx a_rule a_tok _ <<<"$rule"
    [[ -z "$a_idx" || -z "$a_rule" || -z "$a_tok" ]] && continue
    ALLOWED["$a_idx $a_rule $a_tok"]=${why# }
  done < "$ALLOW"
fi
allowed() { [[ -n "${ALLOWED[$1]:-}" ]]; }

# index -> file, first registration wins.
declare -A INDEX_FILE
shopt -s nullglob
for f in "$DIR"/*.json; do
  while IFS= read -r idx; do
    [[ -z "$idx" || -n "${INDEX_FILE[$idx]:-}" ]] && continue
    INDEX_FILE[$idx]=$f
  done < <(jq -r '.proposal.specs[]?.index // empty' "$f" 2>/dev/null)
done
shopt -u nullglob

# Base specs for the UNIMPORTED check are derived, not hardcoded: an index that
# >= MIN_FANIN distinct specs already import is a shared surface a new chain is
# expected to inherit rather than retype. The fan-in cut is what separates a base
# (ETH1: 64 importers, COSMOSSDK50: 11, BTC: 8) from a chain spec that merely has
# a testnet child (PEAQ: 1) — without it, every Substrate chain "declares 105 LIT
# methods" and the signal drowns. A future SUBSTRATE base is picked up the day
# enough specs import it.
declare -A FANIN
shopt -s nullglob
for f in "$DIR"/*.json; do
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    FANIN[$p]=$(( ${FANIN[$p]:-0} + 1 ))
  done < <(jq -r '.proposal.specs[]?.imports[]?' "$f" 2>/dev/null)
done
shopt -u nullglob
BASES=()
for b in "${!FANIN[@]}"; do (( FANIN[$b] >= MIN_FANIN )) && BASES+=("$b"); done

# collection key + method rows for one index: "<iface>|<ip>|<type>|<addon>\t<method>\t<enabled>"
rows_for() {
  local idx=$1 file=${INDEX_FILE[$1]:-}
  [[ -n "$file" ]] || return 0
  jq -r --arg i "$idx" '
    .proposal.specs[] | select(.index==$i) | .api_collections[]? as $c
    | $c.collection_data as $d
    | $c.apis[]?
    | "\($d.api_interface)|\($d.internal_path)|\($d.type)|\($d.add_on)\t\(.name)\t\(if .enabled == false then "off" else "on" end)\t\({bp:.block_parsing, cu:.compute_units, cat:.category, en:.enabled, to:.timeout_ms} | tojson)"
  ' "$file"
}

# transitive imports of one index, excluding itself
closure_of() {
  local start=$1
  declare -A seen=()
  local queue=("$start") cur file p
  while ((${#queue[@]})); do
    cur=${queue[0]}; queue=("${queue[@]:1}")
    file=${INDEX_FILE[$cur]:-}
    [[ -n "$file" ]] || continue
    while IFS= read -r p; do
      [[ -z "$p" || -n "${seen[$p]:-}" ]] && continue
      seen[$p]=1; queue+=("$p")
    done < <(jq -r --arg i "$cur" '.proposal.specs[] | select(.index==$i) | .imports[]?' "$file")
  done
  printf '%s\n' "${!seen[@]}"
}

FAIL=(); PASS=()

while IFS= read -r idx; do
  [[ -z "$idx" ]] && continue
  mapfile -t parents < <(closure_of "$idx")

  # own methods, keyed by collection
  declare -A own=() own_state=() own_name=() own_body=()
  while IFS=$'\t' read -r ck m st body; do
    [[ -z "$ck" ]] && continue
    own["$ck|$m"]=1; own_state["$ck|$m"]=$st; own_name[$m]=1; own_body["$ck|$m"]=$body
  done < <(rows_for "$idx")

  # REDUNDANT: parent declares the same method in the same collection
  dup=0; drift_list=""
  for p in "${parents[@]:-}"; do
    [[ -z "$p" ]] && continue
    while IFS=$'\t' read -r ck m _ pbody; do
      [[ -z "$ck" ]] && continue
      k="$ck|$m"
      [[ -n "${own[$k]:-}" ]] || continue
      [[ "${own_state[$k]}" == "off" ]] && continue   # deliberate disable — allowed
      # only a byte-identical copy is dead weight; a real override is a decision
      [[ "${own_body[$k]:-}" == "${pbody:-}" ]] || continue
      if allowed "$idx REDUNDANT $m"; then
        PASS+=("$idx|REDUNDANT $m|allowed: ${ALLOWED["$idx REDUNDANT $m"]}"); continue
      fi
      dup=$((dup+1)); drift_list+=" $m($p)"
    done < <(rows_for "$p")
  done
  if (( dup > 0 )); then
    FAIL+=("REDUNDANT|$idx|$dup method(s) re-declared byte-identically to an imported parent — delete them:${drift_list}")
  fi

  # UNIMPORTED: >= THRESHOLD of a base's methods retyped without importing it
  for b in "${BASES[@]}"; do
    [[ "$idx" == "$b" ]] && continue
    [[ -n "${INDEX_FILE[$b]:-}" ]] || continue
    reached=0
    for p in "${parents[@]:-}"; do [[ "$p" == "$b" ]] && reached=1; done
    (( reached )) && continue
    # skip a base that already depends on this spec — COSMOSSDK50 imports
    # COSMOSSDK, so "COSMOSSDK never imports COSMOSSDK50" is the arrow backwards
    revdep=0
    while IFS= read -r r; do [[ "$r" == "$idx" ]] && revdep=1; done < <(closure_of "$b")
    (( revdep )) && continue
    n=0
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      [[ -n "${own_name[$m]:-}" ]] && n=$((n+1))
    done < <(rows_for "$b" | cut -f2 | sort -u)
    if (( n >= THRESHOLD )) && allowed "$idx UNIMPORTED $b"; then
      PASS+=("$idx|UNIMPORTED $b|allowed: ${ALLOWED["$idx UNIMPORTED $b"]}")
    elif (( n >= THRESHOLD )); then
      FAIL+=("UNIMPORTED|$idx|declares $n $b methods but never imports $b — import it, or record the endpoint probe showing $b's RPC lives on a different host")
    else
      PASS+=("$idx|$b|$n shared method(s), under threshold $THRESHOLD")
    fi
  done
  unset own own_state own_name own_body
done < <(jq -r '.proposal.specs[].index' "$SPEC")

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
