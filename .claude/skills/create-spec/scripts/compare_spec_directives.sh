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

# Resolve parent specs by CONTENT, not filename (same algorithm as
# compare_spec_methods.sh). This repo is flat: every spec is a *.json at the
# repo root, beside the candidate. Scan that directory and match imports to
# whichever file declares the index (e.g. ETH1 lives in ethereum.json).
declare -A INDEX_FILE

register_dir() {  # index every *.json in a directory into INDEX_FILE
  local dir=$1 f idx
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  for f in "$dir"/*.json; do
    while IFS= read -r idx; do
      [[ -z "$idx" || -n "${INDEX_FILE[$idx]:-}" ]] && continue
      INDEX_FILE[$idx]=$f
    done < <(jq -r '.proposal.specs[]?.index // empty' "$f" 2>/dev/null)
  done
  shopt -u nullglob
}

register_dir "$(dirname "$SPEC")"

resolve_parent() {  # $1 = index -> prints source file path, or fails
  local f=${INDEX_FILE[$1]:-}
  [[ -n "$f" ]] && { printf '%s\n' "$f"; return 0; }
  echo "warn: parent spec '$1' not found in any spec file at the repo root" >&2
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
