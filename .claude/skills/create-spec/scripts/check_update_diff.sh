#!/usr/bin/env bash
# check_update_diff.sh — declared-diff guard for "update an existing spec" mode.
#
# Update mode both ADDS what research found missing and CORRECTS drift in
# entries that already exist, so the add-testnet guard ("nothing pre-existing
# may change", check_preservation.sh) cannot be used here. This guard enforces
# the next-strongest property instead:
#
#     every semantic difference between base and candidate must be DECLARED,
#     in advance, in the plan file — and every declared change must be applied.
#
# An undeclared edit fails the run even when it is individually harmless. That
# is what keeps a re-emit of the file from silently drifting values the way
# PR #80 did (average_block_time 200->35, a parse arg block_height->block_hash),
# while still allowing update mode to deliberately fix exactly those values.
#
# Deletion is never in scope: a removed spec, collection, api, extension,
# directive, verification or even a single removed FIELD fails unconditionally
# and cannot be declared.
#
# Usage:
#   check_update_diff.sh <base.json> <candidate.json> <plan.tsv>
#   check_update_diff.sh --emit <base.json> <candidate.json>   # seed a plan
#
#   base.json       the pre-edit file (`git show origin/main:<chain>.json`)
#   candidate.json  the file after update mode wrote to it
#   plan.tsv        the change plan (see FORMAT below)
#
# FORMAT — plan.tsv is tab-separated, 5 columns; blank lines and lines starting
# with '#' are ignored:
#
#   ACTION <TAB> TARGET <TAB> FIELD <TAB> NOTE <TAB> EVIDENCE
#
#   ACTION    ADD | MODIFY
#   TARGET    an identity key as printed by spec_leaves.jq, e.g.
#               S:ETH1
#               S:ETH1|C:jsonrpc~~POST~
#               S:ETH1|C:jsonrpc~~POST~|A:eth_getProof
#               S:ETH1|C:jsonrpc~~POST~|E:archive
#   FIELD     ADD rows: '-'.  MODIFY rows: the leaf path inside TARGET,
#             e.g. compute_units, block_parsing.parser_arg[0], category.deterministic
#   NOTE      free text for the PR table (may be '-')
#   EVIDENCE  required on MODIFY rows: a URL, or 'probe:<report-line>' for a
#             value proven wrong by the live probe. ADD rows may use '-'.
#
# Declaring an ADD for a target covers everything inside it — you do not need a
# row per api of a newly added collection.
#
# Exit: 0 PASS · 1 FAIL (undeclared/forbidden/unapplied change) · 2 usage or
# unparseable input.
set -euo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "$0")" && pwd)"
JQPROG="$DIR/spec_leaves.jq"

EMIT=0
if [[ "${1:-}" == "--emit" ]]; then EMIT=1; shift; fi

if { [[ $EMIT -eq 1 ]] && [[ $# -ne 2 ]]; } || { [[ $EMIT -eq 0 ]] && [[ $# -ne 3 ]]; }; then
  echo "usage: $0 <base.json> <candidate.json> <plan.tsv>" >&2
  echo "       $0 --emit <base.json> <candidate.json>" >&2
  exit 2
fi
BASE=$1
CAND=$2
PLAN=${3:-}

[[ -r "$JQPROG" ]] || { echo "missing leaf program: $JQPROG" >&2; exit 2; }
for f in "$BASE" "$CAND"; do
  [[ -r "$f" ]] || { echo "cannot read: $f" >&2; echo "RESULT: FAIL (unreadable: $f)"; exit 2; }
  # An empty file is checked before jq runs: jq's exit code for zero input is
  # version-dependent (1.6 reports success, 1.7 reports no-output), so only an
  # explicit test refuses a truncated-to-nothing spec on every runner.
  [[ -s "$f" ]] || { echo "INVALID_JSON | $f (empty)" >&2; echo "RESULT: FAIL (empty file: $f)"; exit 2; }
  # Fail closed on unparseable input — a malformed candidate must never pass.
  jq empty "$f" 2>/dev/null || { echo "INVALID_JSON | $f" >&2; echo "RESULT: FAIL (invalid JSON: $f)"; exit 2; }
done
if [[ $EMIT -eq 0 ]]; then
  [[ -r "$PLAN" ]] || { echo "cannot read plan: $PLAN" >&2; echo "RESULT: FAIL (unreadable plan)"; exit 2; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check_update_diff.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

dump() { jq -rf "$JQPROG" "$1" | LC_ALL=C sort; }
dump "$BASE" > "$WORK/base.tsv"
dump "$CAND" > "$WORK/cand.tsv"

PASS=()
FAIL=()

# ---------------------------------------------------------------- identities
# Two apis with the same name in one collection collapse to one key, which would
# hide a change. That is a spec defect in its own right — fail loudly.
for side in base cand; do
  dupes=$(awk -F'\t' '$1 ~ /\|@$/ {print $1}' "$WORK/$side.tsv" | uniq -d || true)
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    FAIL+=("duplicate-identity|${d%|@}|same identity appears twice in $side (a spec defect: rename or merge)")
  done <<< "$dupes"
done

# Targets = every key ending in |@ , stripped of that suffix.
targets() { awk -F'\t' '$1 ~ /\|@$/ {sub(/\|@$/,"",$1); print $1}' "$1"; }
targets "$WORK/base.tsv" | sort -u > "$WORK/base.targets"
targets "$WORK/cand.tsv" | sort -u > "$WORK/cand.targets"
comm -23 "$WORK/base.targets" "$WORK/cand.targets" > "$WORK/removed.targets"
comm -13 "$WORK/base.targets" "$WORK/cand.targets" > "$WORK/added.targets"

# --------------------------------------------------------------------- plan
# Normalize the plan into "ACTION<TAB>TARGET<TAB>FIELD<TAB>EVIDENCE".
: > "$WORK/plan.norm"
if [[ $EMIT -eq 0 ]]; then
  lineno=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    raw=${raw%$'\r'}
    [[ -z "${raw//[[:space:]]/}" ]] && continue
    [[ "${raw#\#}" != "$raw" ]] && continue
    IFS=$'\t' read -r action target field note evidence <<< "$raw"
    note=${note:-}
    if [[ -z "${target:-}" ]]; then
      FAIL+=("plan-malformed|line $lineno|expected 5 tab-separated columns: ACTION TARGET FIELD NOTE EVIDENCE")
      continue
    fi
    case "$action" in
      ADD|MODIFY) ;;
      *) FAIL+=("plan-bad-action|line $lineno|'$action' is not ADD or MODIFY"); continue ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$action" "$target" "${field:--}" "${evidence:-}" >> "$WORK/plan.norm"
  done < "$PLAN"
fi
sort -u "$WORK/plan.norm" > "$WORK/plan.sorted" 2>/dev/null || : > "$WORK/plan.sorted"
awk -F'\t' '$1=="ADD"{print $2}' "$WORK/plan.sorted" | sort -u > "$WORK/plan.adds"

# An ADD of a target covers every descendant, so a declared parent satisfies its
# children without a row each.
covered_by_add() {  # $1 = target key
  local t=$1 p
  p=$t
  while :; do
    grep -qxF "$p" "$WORK/plan.adds" && return 0
    [[ "$p" != *"|"* ]] && return 1
    p=${p%|*}
  done
}

# ------------------------------------------------------- removals (never ok)
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  FAIL+=("removed-target|$t|deletion is never in scope for update mode")
done < "$WORK/removed.targets"

# ------------------------------------------------------------ added targets
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  if [[ $EMIT -eq 1 ]]; then continue; fi
  if covered_by_add "$t"; then
    PASS+=("added|$t|declared")
  else
    FAIL+=("undeclared-add|$t|added to the spec but not declared in the plan")
  fi
done < "$WORK/added.targets"

# ------------------------------------------------- leaves of kept targets
# Ignore leaves under added targets (covered by the ADD) and under removed ones
# (already failed above). Everything else must match, leaf for leaf.
cat "$WORK/added.targets" "$WORK/removed.targets" | sort -u > "$WORK/skip.targets"

# The skip set is read in BEGIN, not via the NR==FNR idiom: when the skip file is
# empty (the common "nothing added, nothing removed" case) NR==FNR stays true for
# every line of stdin, which swallowed the entire dump and made the guard pass
# vacuously. Reading it in BEGIN is also what compare_spec_methods.sh does.
keep_filter() {  # stdin: "key<TAB>value" -> only rows whose target survives in both
  awk -F'\t' -v skipfile="$WORK/skip.targets" '
    BEGIN {
      while ((getline line < skipfile) > 0)
        if (line != "") skip[line] = 1
      close(skipfile)
    }
    {
      t=$1
      sub(/\|[^|]*$/, "", t)        # strip the field component -> target
      while (1) {
        if (t in skip) next
        i = match(t, /\|[^|]*$/)
        if (i == 0) break
        t = substr(t, 1, i-1)
      }
      print
    }
  '
}
{ keep_filter < "$WORK/base.tsv" | grep -v $'|@\t1$' || true; } | sort > "$WORK/base.keep"
{ keep_filter < "$WORK/cand.tsv" | grep -v $'|@\t1$' || true; } | sort > "$WORK/cand.keep"

: > "$WORK/changes"     # "<target>\t<field>\t<old>\t<new>"
join -t$'\t' -j1 -o 0,1.2,2.2 \
     <(cut -f1,2 "$WORK/base.keep") <(cut -f1,2 "$WORK/cand.keep") 2>/dev/null \
  | awk -F'\t' '$2 != $3 { print }' > "$WORK/common.diff" || true
while IFS=$'\t' read -r key old new; do
  [[ -z "$key" ]] && continue
  printf '%s\t%s\t%s\t%s\n' "${key%|*}" "${key##*|}" "$old" "$new" >> "$WORK/changes"
done < "$WORK/common.diff"

# A field present in only one side: added field -> a MODIFY; removed field -> fail.
comm -13 <(cut -f1 "$WORK/base.keep") <(cut -f1 "$WORK/cand.keep") > "$WORK/leaf.added"
comm -23 <(cut -f1 "$WORK/base.keep") <(cut -f1 "$WORK/cand.keep") > "$WORK/leaf.removed"
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  new=$(awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$WORK/cand.keep")
  printf '%s\t%s\t%s\t%s\n' "${key%|*}" "${key##*|}" "(absent)" "$new" >> "$WORK/changes"
done < "$WORK/leaf.added"
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  FAIL+=("removed-field|${key%|*}|field '${key##*|}' was deleted — removal is never in scope")
done < "$WORK/leaf.removed"

# ------------------------------------------------------------------- --emit
if [[ $EMIT -eq 1 ]]; then
  echo "# plan seeded by check_update_diff.sh --emit — fill in NOTE and EVIDENCE"
  printf '# ACTION\tTARGET\tFIELD\tNOTE\tEVIDENCE\n'
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    printf 'ADD\t%s\t-\t-\t-\n' "$t"
  done < "$WORK/added.targets"
  sort -u "$WORK/changes" | while IFS=$'\t' read -r target field old new; do
    [[ -z "$target" ]] && continue
    printf 'MODIFY\t%s\t%s\t%s -> %s\t\n' "$target" "$field" "$old" "$new"
  done
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    printf '# REMOVED (never allowed, fix the candidate): %s\n' "$t"
  done < "$WORK/removed.targets"
  exit 0
fi

# ------------------------------------------------ MODIFY: declared + allowed
# Fields that update mode may correct. Everything else is identity or structure:
# changing it is a delete+add in disguise, so it is refused even when declared.
allowed_field() {
  case "$1" in
    compute_units|enabled|timeout_ms|cu_multiplier|api_name|function_template) return 0 ;;
    average_block_time|block_distance_for_finalized_data) return 0 ;;
    blocks_in_finalization_proof|allowed_block_lag_for_qos_sync) return 0 ;;
    block_parsing.*|'parsers['*|category.*|rule.*|'values['*) return 0 ;;
    result_parsing.*|parse_directive.*) return 0 ;;
    *) return 1 ;;
  esac
}

: > "$WORK/matched.plan"
: > "$WORK/seen.changes"
while IFS=$'\t' read -r target field old new; do
  [[ -z "$target" ]] && continue
  row="MODIFY"$'\t'"$target"$'\t'"$field"
  # Every real change is recorded here before it is judged, so that a row which
  # IS applied but fails validation reports only its actual violation and is not
  # also reported as "not applied" by the pass below.
  printf '%s\n' "$row" >> "$WORK/seen.changes"
  if ! allowed_field "$field"; then
    FAIL+=("forbidden-field|$target|'$field' identifies or structures the entry ($old -> $new); it may not be modified in update mode")
    continue
  fi
  evidence=$(awk -F'\t' -v t="$target" -v f="$field" \
               '$1=="MODIFY" && $2==t && $3==f {print $4; exit}' "$WORK/plan.sorted")
  if [[ -z "$evidence" ]]; then
    if awk -F'\t' -v t="$target" -v f="$field" \
         '$1=="MODIFY" && $2==t && $3==f {found=1} END{exit !found}' "$WORK/plan.sorted"; then
      FAIL+=("no-evidence|$target|MODIFY $field ($old -> $new) is declared without evidence")
    else
      FAIL+=("undeclared-modify|$target|'$field' changed $old -> $new but no MODIFY row declares it")
    fi
    continue
  fi
  # Disabling something needs positive evidence of absence. A probe error on a
  # public node is a free-tier artifact, never proof (Phase 5 disable rule).
  if [[ "$field" == "enabled" && "$old" == "true" && "$new" == "false" && "$evidence" == probe:* ]]; then
    FAIL+=("probe-only-disable|$target|enabled true->false justified only by '$evidence'; needs docs or client-source evidence")
    continue
  fi
  printf '%s\n' "$row" >> "$WORK/matched.plan"
  PASS+=("modified|$target|$field $old -> $new")
done < <(sort -u "$WORK/changes")

# --------------------------------------------- plan rows that never landed
while IFS=$'\t' read -r action target field evidence; do
  [[ -z "$action" ]] && continue
  if [[ "$action" == "ADD" ]]; then
    grep -qxF "$target" "$WORK/added.targets" && continue
    # An ADD row for something that already existed is a no-op the author
    # believed was a change — surface it rather than silently passing.
    if grep -qxF "$target" "$WORK/base.targets"; then
      FAIL+=("not-applied|$target|plan declares ADD but the target already existed in the base")
    else
      FAIL+=("not-applied|$target|plan declares ADD but the candidate does not contain it")
    fi
  else
    grep -qxF "MODIFY"$'\t'"$target"$'\t'"$field" "$WORK/seen.changes" 2>/dev/null && continue
    FAIL+=("not-applied|$target|plan declares MODIFY $field but the candidate is unchanged there")
  fi
done < "$WORK/plan.sorted"

# ---------------------------------------------------------------- envelope
tl_base=$(jq -S -c 'keys' "$BASE"); tl_cand=$(jq -S -c 'keys' "$CAND")
[[ "$tl_base" == "$tl_cand" ]] && PASS+=("top-level-keys|ok|unchanged") \
  || FAIL+=("top-level-keys|changed|base=$tl_base cand=$tl_cand")
pk_base=$(jq -S -c '.proposal | keys' "$BASE"); pk_cand=$(jq -S -c '.proposal | keys' "$CAND")
[[ "$pk_base" == "$pk_cand" ]] && PASS+=("proposal-keys|ok|unchanged") \
  || FAIL+=("proposal-keys|changed|base=$pk_base cand=$pk_cand")

# Spec entries must keep their order — a reorder is invisible to the identity
# keying above but changes the file for every other reader.
ord_base=$(jq -c '[.proposal.specs[].index]' "$BASE")
ord_cand=$(jq -c --argjson b "$ord_base" \
             '[.proposal.specs[].index] | map(select(. as $i | $b | index($i) != null))' "$CAND")
[[ "$ord_base" == "$ord_cand" ]] && PASS+=("spec-order|ok|pre-existing specs keep their order") \
  || FAIL+=("spec-order|changed|base=$ord_base candidate-order=$ord_cand")

echo "=== PASS ==="
printf '%s\n' ${PASS[@]+"${PASS[@]}"}
echo
echo "=== FAIL ==="
printf '%s\n' ${FAIL[@]+"${FAIL[@]}"}

added_n=$(grep -c . "$WORK/added.targets" || true)
mod_n=$(sort -u "$WORK/changes" | grep -c . || true)
if [[ ${#FAIL[@]} -eq 0 ]]; then
  echo
  echo "RESULT: PASS ($added_n added, $mod_n modified — all declared; nothing removed)"
  exit 0
fi
echo
echo "RESULT: FAIL (${#FAIL[@]} violation(s))"
exit 1
