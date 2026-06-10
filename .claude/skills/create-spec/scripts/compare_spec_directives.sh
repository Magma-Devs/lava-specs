#!/usr/bin/env bash
# spec-directives-diff: compare a candidate spec's parse_directives against
# a ground-truth list emitted by the upstream-spec-scout agent.
#
# Usage:
#   spec-directives-diff <spec.json> <directives-file>
#
# Directives file format (one row per directive):
#   <function_tag>|<api_name>|<sha256_of_function_template>
#
# function_template hash: sha256 of the literal function_template string from
# the source spec (no whitespace stripping, no normalization). null templates
# are encoded as the literal string "null".
#
# The script walks .imports[] transitively (same algorithm as
# compare_spec_methods.sh) and emits four sections:
#   PRESENT, MISSING, EXTRA IN SPEC, HASH-MISMATCH

set -euo pipefail
export LC_ALL=C

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <spec.json> <directives-file>" >&2
  exit 2
fi

SPEC=$(realpath -- "$1")
LIST=$2
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }
[[ -r "$LIST" ]] || { echo "cannot read directives file: $LIST" >&2; exit 1; }

# Locate specs-root (ancestor containing mainnet-1/specs or testnet-2/specs).
SEARCH=$(dirname "$SPEC")
SPECS_ROOT=""
while [[ "$SEARCH" != "/" ]]; do
  if [[ -d "$SEARCH/mainnet-1/specs" || -d "$SEARCH/testnet-2/specs" ]]; then
    SPECS_ROOT=$SEARCH; break
  fi
  SEARCH=$(dirname "$SEARCH")
done

resolve_parent() {
  if [[ -z "$SPECS_ROOT" ]]; then
    echo "warn: cannot resolve parent spec '$1' (no specs root found above candidate spec)" >&2
    return 1
  fi
  local idx_lower
  idx_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for d in testnet-2 mainnet-1; do
    local f="$SPECS_ROOT/$d/specs/$idx_lower.json"
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  echo "warn: parent spec '$1' not found under $SPECS_ROOT/{testnet-2,mainnet-1}/specs/" >&2
  return 1
}

# BFS over import graph.
declare -A SEEN
mapfile -t START < <(jq -r '.proposal.specs[].index' "$SPEC")
queue=()
for i in "${START[@]}"; do
  SEEN[$i]=$SPEC
  queue+=("$i")
done

while ((${#queue[@]})); do
  cur=${queue[0]}; queue=("${queue[@]:1}")
  cur_file=${SEEN[$cur]}
  while IFS= read -r p; do
    [[ -z "$p" || -n "${SEEN[$p]:-}" ]] && continue
    if pf=$(resolve_parent "$p"); then
      SEEN[$p]=$pf
      queue+=("$p")
    fi
  done < <(jq -r --arg idx "$cur" '.proposal.specs[] | select(.index == $idx) | .imports[]?' "$cur_file")
done

hash_template() {
  if [[ "$1" == "null" || -z "$1" ]]; then
    printf 'null'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# Collect spec directives into key/value maps.
declare -A SPEC_BY_KEY
for idx in "${!SEEN[@]}"; do
  file=${SEEN[$idx]}
  while IFS=$'\t' read -r tag api tmpl; do
    [[ -z "$tag" ]] && continue
    h=$(hash_template "$tmpl")
    SPEC_BY_KEY["${tag}|${api}"]=$h
  done < <(jq -r --arg idx "$idx" '
    .proposal.specs[] | select(.index == $idx)
    | .api_collections[]?
    | .parse_directives[]?
    | "\(.function_tag)\t\(.api_name // "")\t\(.function_template // "null")"
  ' "$file")
done

# Read ground-truth rows (skip blank/comment lines).
declare -A WANT_BY_KEY
while IFS= read -r raw; do
  line=$(printf '%s' "$raw" | sed -E 's/#.*$//; s/[[:space:]]+$//; s/^[[:space:]]+//')
  [[ -z "$line" ]] && continue
  IFS='|' read -r tag api hash <<< "$line"
  WANT_BY_KEY["${tag}|${api}"]=$hash
done < "$LIST"

echo "=== PRESENT (tag|api in both spec and ground truth, hashes match) ==="
for k in "${!WANT_BY_KEY[@]}"; do
  if [[ -n "${SPEC_BY_KEY[$k]:-}" && "${SPEC_BY_KEY[$k]}" == "${WANT_BY_KEY[$k]}" ]]; then
    echo "$k"
  fi
done | sort
echo

echo "=== MISSING (in ground truth, not in spec) ==="
for k in "${!WANT_BY_KEY[@]}"; do
  if [[ -z "${SPEC_BY_KEY[$k]:-}" ]]; then
    echo "$k"
  fi
done | sort
echo

echo "=== EXTRA IN SPEC (in spec, not in ground truth) ==="
for k in "${!SPEC_BY_KEY[@]}"; do
  if [[ -z "${WANT_BY_KEY[$k]:-}" ]]; then
    echo "$k"
  fi
done | sort
echo

echo "=== HASH-MISMATCH (same tag|api, different function_template hash) ==="
for k in "${!WANT_BY_KEY[@]}"; do
  if [[ -n "${SPEC_BY_KEY[$k]:-}" && "${SPEC_BY_KEY[$k]}" != "${WANT_BY_KEY[$k]}" ]]; then
    echo "$k  spec=${SPEC_BY_KEY[$k]}  want=${WANT_BY_KEY[$k]}"
  fi
done | sort
