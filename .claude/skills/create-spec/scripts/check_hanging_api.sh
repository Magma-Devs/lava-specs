#!/usr/bin/env bash
# check_hanging_api.sh — the three `category.hanging_api` rules, verified against
# the smart-router source rather than inferred from the specs.
#
# `hanging_api` feeds exactly one thing: protocol/chainlib/common.go:575,
#
#   func GetRelayTimeout(chainMessage, averageBlockTime) time.Duration {
#       if chainMessage.TimeoutOverride() != 0 { return chainMessage.TimeoutOverride() }
#       extraRelayTimeout := 0
#       if IsHangingApi(chainMessage) { extraRelayTimeout = averageBlockTime * 2 }
#       relayTimeAddition := common.GetTimePerCu(GetComputeUnits(chainMessage))
#       if chainMessage.GetApi().TimeoutMs > 0 {
#           relayTimeAddition = time.Millisecond * time.Duration(chainMessage.GetApi().TimeoutMs)
#       }
#       return extraRelayTimeout + relayTimeAddition
#   }
#
# Two consequences drive the checks below.
#
# SUBSCRIBE never reaches it. protocol/chainlib/consumer_websocket_manager.go:298
# branches on the SUBSCRIBE function tag and hands the message to
# StartSubscription; the four GetRelayTimeout call sites are all on the unary
# path, and neither subscription manager references it. A subscription's lifetime
# is its socket's — nothing in the spec bounds it. So on a SUBSCRIBE-tagged API,
# `hanging_api`, `compute_units` and `timeout_ms` are dead inputs, and setting
# `hanging_api` there states something the router will never read. 3 of 288
# SUBSCRIBE-registered APIs across the catalogue do this (MAG-3389).
#
# `timeout_ms` REPLACES the CU term, it does not add to it. So a `timeout_ms`
# below `CU * 100` ms *shortens* the relay budget relative to setting nothing at
# all — the opposite of why anyone sets it. Real case: Acala's watch pair at
# CU 1000 carries a 100 000 ms implied base; a reflexive `timeout_ms: 30000`
# would have cut it from 124s to 54s (MAG-3389, PR #136).
#
# The third check automates the rule stated at create-spec/SKILL.md:263 and
# agents/spec-builder.md:59 — "Every API with category.hanging_api: true has an
# explicit timeout_ms" — which those docs flag as having no validator coverage.
#
# Scope note: this gate reads the CANDIDATE file only, which is how the pipeline
# uses it. 152 APIs across ~30 established specs (ethereum, cosmossdk, tendermint,
# solana, kusama …) predate the timeout_ms rule and would fail check 3 if it were
# ever run over the whole repo. That is a separate cleanup, not this gate's job.
#
# SUBSCRIBE names are collected inheritance-aware: the candidate's own directives
# plus every transitive parent's, resolved through the `imports` graph the same
# way check_directive_presence.sh does, because an L2 that imports ETH1 carries an
# empty parse_directives array of its own.
#
# Usage: check_hanging_api.sh <spec.json>
# Prints "=== PASS ===" / "=== FAIL ===" sections; exit 1 if any FAIL row.

set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <spec.json>" >&2
  exit 2
fi
SPEC=$(realpath -- "$1")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

# ---- index -> file map over every *.json beside the candidate (flat repo). First wins.
declare -A INDEX_FILE
shopt -s nullglob
for f in "$(dirname "$SPEC")"/*.json; do
  while IFS= read -r idx; do
    [[ -z "$idx" || -n "${INDEX_FILE[$idx]:-}" ]] && continue
    INDEX_FILE[$idx]=$f
  done < <(jq -r '.proposal.specs[]?.index // empty' "$f" 2>/dev/null)
done
shopt -u nullglob

# ---- BFS the import graph, unioning SUBSCRIBE api_names from candidate + parents.
declare -A SEEN
queue=()
while IFS= read -r i; do
  [[ -n "$i" ]] && { SEEN[$i]=1; queue+=("$i"); }
done < <(jq -r '.proposal.specs[].index' "$SPEC")

subscribe_names_of() {
  jq -r '.proposal.specs[]?.api_collections[]?.parse_directives[]?
         | select(.function_tag=="SUBSCRIBE") | .api_name // empty' "$1" 2>/dev/null
}

SUBS=$(subscribe_names_of "$SPEC")
while ((${#queue[@]})); do
  cur=${queue[0]}; queue=("${queue[@]:1}")
  cur_file=${INDEX_FILE[$cur]:-$SPEC}
  while IFS= read -r p; do
    [[ -z "$p" || -n "${SEEN[$p]:-}" ]] && continue
    SEEN[$p]=1
    pf=${INDEX_FILE[$p]:-}
    if [[ -n "$pf" ]]; then
      queue+=("$p")
      SUBS+=$'\n'$(subscribe_names_of "$pf")
    fi
  done < <(jq -r --arg idx "$cur" '.proposal.specs[] | select(.index==$idx) | .imports[]?' "$cur_file" 2>/dev/null)
done
SUBS=$(printf '%s\n' "$SUBS" | grep -v '^$' | sort -u || true)

PASS=()
FAIL=()

# ---- evaluate every hanging API in the candidate.
# jq emits: index <TAB> interface <TAB> name <TAB> cu <TAB> timeout_ms (0 = unset)
while IFS=$'\t' read -r idx iface name cu tms; do
  [[ -z "$name" || "$name" == "null" ]] && continue
  ROW="$idx/$iface/$name"

  # 1. hanging_api on a SUBSCRIBE-tagged API — the router never reads it.
  if grep -qxF -- "$name" <<<"$SUBS"; then
    FAIL+=("$ROW|hanging_api set on a SUBSCRIBE-tagged API; the subscription path never reaches GetRelayTimeout, so this flag is never read — remove category.hanging_api")
    continue
  fi

  implied=$(( cu * 100 ))
  (( implied < 1000 )) && implied=1000   # GetTimePerCu floors at 1s

  # 2. hanging_api: true with no timeout_ms (SKILL.md:263).
  if (( tms == 0 )); then
    FAIL+=("$ROW|hanging_api: true with no timeout_ms (SKILL.md:263); relay budget falls back to the CU-derived ${implied}ms + 2x block time")
    continue
  fi

  # 3. timeout_ms below the CU-implied floor — it replaces that term, so this shortens.
  if (( tms < implied )); then
    FAIL+=("$ROW|timeout_ms ${tms}ms is below the CU-implied ${implied}ms (cu=${cu}); timeout_ms REPLACES the CU term, so this SHORTENS the relay budget — raise it above ${implied} or lower compute_units")
    continue
  fi

  PASS+=("$ROW|hanging ok (cu=${cu}, timeout_ms=${tms}ms >= ${implied}ms implied)")
done < <(jq -r '
  .proposal.specs[]? as $s
  | $s.api_collections[]? as $c
  | $c.apis[]?
  | select(.category.hanging_api == true)
  | [ $s.index,
      ($c.collection_data.api_interface // $c.collection_data.apiInterface // "?"),
      .name,
      (.compute_units // 0),
      (.timeout_ms // 0)
    ] | @tsv' "$SPEC")

echo "=== PASS ==="
((${#PASS[@]})) && printf '%s\n' "${PASS[@]}"
echo
echo "=== FAIL ==="
((${#FAIL[@]})) && printf '%s\n' "${FAIL[@]}"

if ((${#FAIL[@]})); then
  exit 1
fi
exit 0
