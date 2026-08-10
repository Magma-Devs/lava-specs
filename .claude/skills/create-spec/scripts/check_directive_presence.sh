#!/usr/bin/env bash
# check_directive_presence.sh — inheritance-aware boot-critical parse-directive presence check.
#
# The smart-router chain tracker cannot initialize without a GET_BLOCKNUM
# parse_directive. But on a flat repo many specs INHERIT their directives from a
# parent (EVM L2s import ETH1; Cosmos chains import COSMOSSDK/TENDERMINT), so
# their own `parse_directives` arrays are empty by design. A naive check on the
# candidate file alone false-FAILs every such spec.
#
# This walks the candidate's `imports` graph (resolving each index to whichever
# sibling *.json declares it, exactly like compare_spec_methods.sh) and checks the
# UNION of the candidate plus all transitive parents.
#
# GET_BLOCKNUM is HARD-REQUIRED — with no head the tracker cannot start at all.
#
# GET_BLOCK_BY_NUM is ADVISORY, not fatal. It used to be hard-required, on the
# premise that the tracker cannot initialize without it. smart-router PR #245
# invalidated that premise: a spec declaring GET_BLOCKNUM but no GET_BLOCK_BY_NUM
# now selects head-only chain tracking (follow the head, keep no block hashes, no
# fork detection). For a chain with no blocks that is the only correct modelling —
# Canton is the first, where ordering is by sequencer timestamp with instant
# finality and no block exists to fetch or hash, so adding a GET_BLOCK_BY_NUM
# directive would describe an operation the chain cannot serve.
#
# For the large majority of chains its absence IS still a defect, so it is
# reported as an INFO line (and passes) rather than being silently ignored — the
# same severity pattern check_pruning.sh uses for unknown retention.
#
# Usage: check_directive_presence.sh <spec.json>
# Prints "OK" (exit 0), optionally preceded by "INFO: ...", or
# "FAIL missing: <tags> (checked indexes: <indexes>)" (exit 1).

set -euo pipefail
export LC_ALL=C

[[ $# -eq 1 ]] || { echo "usage: $0 <spec.json>" >&2; exit 2; }
SPEC=$(realpath -- "$1")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

# Absence is boot-fatal.
REQUIRED=(GET_BLOCKNUM)
# Absence selects head-only chain tracking (smart-router #245): reported, not fatal.
ADVISORY=(GET_BLOCK_BY_NUM)

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

# Advisory tags are reported but never fail the gate. Emitted before the verdict so
# a reviewer sees WHY a spec is head-only rather than assuming the tag was forgotten.
advisory_missing=()
for tag in "${ADVISORY[@]}"; do
  grep -qxF "$tag" <<<"$TAGS" || advisory_missing+=("$tag")
done
if ((${#advisory_missing[@]}>0)); then
  echo "INFO: ${advisory_missing[*]} absent — head-only chain tracking (smart-router #245). Correct for a chain with no blocks; otherwise investigate."
fi

if ((${#missing[@]}==0)); then
  echo "OK"
else
  echo "FAIL missing: ${missing[*]} (checked indexes: ${!SEEN[*]})"
  exit 1
fi
