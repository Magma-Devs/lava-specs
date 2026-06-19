#!/usr/bin/env bash
# check_directive_presence.sh — inheritance-aware boot-critical parse-directive presence check.
#
# The smart-router chain tracker cannot initialize without GET_BLOCKNUM and
# GET_BLOCK_BY_NUM parse_directives. But on a flat repo many specs INHERIT those
# directives from a parent (EVM L2s import ETH1; Cosmos chains import
# COSMOSSDK/TENDERMINT), so their own `parse_directives` arrays are empty by
# design. A naive check on the candidate file alone false-FAILs every such spec.
#
# This walks the candidate's `imports` graph (resolving each index to whichever
# sibling *.json declares it, exactly like compare_spec_methods.sh) and checks
# that GET_BLOCKNUM and GET_BLOCK_BY_NUM are present in the UNION of the candidate
# plus all transitive parents. Hard-FAILs only when a tag is absent everywhere.
#
# Usage: check_directive_presence.sh <spec.json>
# Prints "OK" (exit 0) or "FAIL missing: <tags> (checked: <indexes>)" (exit 1).

set -euo pipefail
export LC_ALL=C

[[ $# -eq 1 ]] || { echo "usage: $0 <spec.json>" >&2; exit 2; }
SPEC=$(realpath -- "$1")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

REQUIRED=(GET_BLOCKNUM GET_BLOCK_BY_NUM)

# index -> file map over every *.json beside the candidate (flat repo). First wins.
declare -A INDEX_FILE
shopt -s nullglob
for f in "$(dirname "$SPEC")"/*.json; do
  while IFS= read -r idx; do
    [[ -z "$idx" || -n "${INDEX_FILE[$idx]:-}" ]] && continue
    INDEX_FILE[$idx]=$f
  done < <(jq -r '.proposal.specs[]?.index // empty' "$f" 2>/dev/null)
done
shopt -u nullglob

# BFS the import graph starting from the candidate's own indexes.
declare -A SEEN
queue=()
while IFS= read -r i; do [[ -n "$i" ]] && { SEEN[$i]=1; queue+=("$i"); }; done \
  < <(jq -r '.proposal.specs[].index' "$SPEC")

# collected tags across candidate + parents
TAGS=$(jq -r '.proposal.specs[].api_collections[]?.parse_directives[]?.function_tag // empty' "$SPEC")

while ((${#queue[@]})); do
  cur=${queue[0]}; queue=("${queue[@]:1}")
  cur_file=${INDEX_FILE[$cur]:-$SPEC}
  while IFS= read -r p; do
    [[ -z "$p" || -n "${SEEN[$p]:-}" ]] && continue
    SEEN[$p]=1
    pf=${INDEX_FILE[$p]:-}
    if [[ -n "$pf" ]]; then
      queue+=("$p")
      TAGS+=$'\n'$(jq -r '.proposal.specs[].api_collections[]?.parse_directives[]?.function_tag // empty' "$pf")
    fi
  done < <(jq -r --arg idx "$cur" '.proposal.specs[] | select(.index==$idx) | .imports[]?' "$cur_file" 2>/dev/null)
done

missing=()
for tag in "${REQUIRED[@]}"; do
  grep -qxF "$tag" <<<"$TAGS" || missing+=("$tag")
done

if ((${#missing[@]}==0)); then
  echo "OK"
else
  echo "FAIL missing: ${missing[*]} (checked indexes: ${!SEEN[*]})"
  exit 1
fi
