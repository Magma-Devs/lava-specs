#!/usr/bin/env bash
# check_hanging_api.sh — the three `category.hanging_api` rules, verified against
# the smart-router source rather than inferred from the specs.
#
# `hanging_api` feeds exactly one thing: the window GetRelayTimeout returns
# (smart-router protocol/chainlib/common.go:600). That function bounds a caller's
# lava-relay-timeout override with common.BoundCallerRelayTimeout; the spec's own
# inputs are read by routerRelayTimeout (common.go:613):
#
#   func routerRelayTimeout(chainMessage, averageBlockTime) time.Duration {
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
# SUBSCRIBE never reaches it. protocol/chainlib/consumer_websocket_manager.go:525
# branches on the SUBSCRIBE function tag and hands the message to
# StartSubscription; every GetRelayTimeout call site is on the unary path, and
# no subscription manager references it. A subscription's lifetime
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
# The third check automates the rule stated in create-spec/SKILL.md (Phase 6,
# pre-flight checklist) and agents/spec-builder.md:59 — "Every API with category.hanging_api: true has an
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
# Base mode (--base <file>): an update, add-testnet or add-collection run edits
# an established spec, which may already carry some of those 152 rows. With a
# base — the same file on origin/main, or Phase 10a's pre-fix snapshot — a FAIL
# row that the base already fails with the identical text is reported under
# INFO as pre-existing, and only rows that are new or changed FAIL. Without a
# base (a new chain) every row is judged, as before.
#
# Usage: check_hanging_api.sh [--base <base.json>] <spec.json>
# Prints "=== PASS ===" / "=== INFO ===" / "=== FAIL ===" sections; exit 1 if
# any FAIL row, 2 on usage or an unreadable base.

set -euo pipefail
export LC_ALL=C

usage() { echo "usage: $0 [--base <base.json>] <spec.json>" >&2; exit 2; }
BASE="" CONTEXT="" SPEC_ARG=""
while (($#)); do
  case "$1" in
    --base) (($# >= 2)) || usage; BASE=$2; shift 2 ;;
    # Internal: judge the base as if it sat at the candidate's path, so its
    # imports resolve against the candidate's siblings, not wherever it was saved.
    --context) (($# >= 2)) || usage; CONTEXT=$2; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$SPEC_ARG" ]] || usage; SPEC_ARG=$1; shift ;;
  esac
done
[[ -n "$SPEC_ARG" ]] || usage
SPEC=$(realpath -- "$SPEC_ARG")
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }
SPECDIR=$(dirname "$(realpath -- "${CONTEXT:-$SPEC}")")

# ---- index -> file map: the spec's own indexes first, then every *.json beside
# it (flat repo). First wins, so a base judged in context resolves to itself.
declare -A INDEX_FILE
while IFS= read -r idx; do
  [[ -n "$idx" ]] && INDEX_FILE[$idx]=$SPEC
done < <(jq -r '.proposal.specs[]?.index // empty' "$SPEC" 2>/dev/null)
shopt -s nullglob
for f in "$SPECDIR"/*.json; do
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
  # GetTimePerCu floors at MinimumTimePerRelayDelay. 1000 assumes its default:
  # a deployment that raises it with --min-relay-timeout raises the real budget
  # too, so this check stays conservative there.
  (( implied < 1000 )) && implied=1000

  # 2. hanging_api: true with no timeout_ms (SKILL.md, Phase 6 pre-flight checklist).
  if (( tms == 0 )); then
    FAIL+=("$ROW|hanging_api: true with no timeout_ms (SKILL.md, Phase 6 pre-flight checklist); relay budget falls back to the CU-derived ${implied}ms + 2x block time")
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

# ---- base mode: demote the rows the base already fails, verbatim.
INFO=()
if [[ -n "$BASE" ]]; then
  jq -e 'type == "object"' "$BASE" >/dev/null 2>&1 || { echo "cannot read base: $BASE" >&2; exit 2; }
  BASE_FAILS=$(bash "$0" --context "$SPEC" "$BASE" 2>/dev/null | sed -n '/^=== FAIL ===$/,$p' | tail -n +2 || true)
  KEPT=()
  for row in ${FAIL[@]+"${FAIL[@]}"}; do
    if grep -qxF -- "$row" <<<"$BASE_FAILS"; then
      INFO+=("$row  [pre-existing: the base fails this row identically]")
    else
      KEPT+=("$row")
    fi
  done
  FAIL=(${KEPT[@]+"${KEPT[@]}"})
fi

echo "=== PASS ==="
((${#PASS[@]})) && printf '%s\n' "${PASS[@]}"
echo
echo "=== INFO ==="
((${#INFO[@]})) && printf '%s\n' "${INFO[@]}"
echo
echo "=== FAIL ==="
((${#FAIL[@]})) && printf '%s\n' "${FAIL[@]}"

if ((${#FAIL[@]})); then
  exit 1
fi
exit 0
