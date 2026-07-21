#!/usr/bin/env bash
# check_preservation.sh — additive-only guard for the "add a testnet to an
# existing <chain>.json" mode.
#
# Asserts that a candidate spec file differs from its base ONLY by the addition
# of exactly one new spec entry (the testnet), and that every pre-existing spec
# and the envelope structure are semantically unchanged. This is the guard that
# makes mainnet drift IMPOSSIBLE in add-testnet mode.
#
# Why this exists in addition to check_unused_fields.sh: that guard only flags
# removed field *names*; it is blind to a mainnet whose VALUES were silently
# regenerated (e.g. PR #80 drifted average_block_time 200->35 and a parse arg
# block_height->block_hash — both pass check_unused_fields). This gate compares
# every pre-existing spec byte-for-byte (canonicalised) against the base and
# fails on any such semantic drift.
#
# Comparison is on jq -S canonical form (recursive key-sort), so it is immune to
# whitespace/key-order but catches every value, field add/remove, and array
# reorder inside a pre-existing spec.
#
# Usage:
#   check_preservation.sh <base.json> <candidate.json> <NEW_INDEX>
#     base.json      the pre-edit file (e.g. `git show origin/main:<chain>.json`)
#     candidate.json the file after the testnet was appended
#     NEW_INDEX      the uppercase index of the testnet that should be the ONLY
#                    added spec (e.g. APTOST)
#
# Exit: 0 PASS · 1 FAIL (drift/structure) · 2 usage or unparseable input.
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <base.json> <candidate.json> <NEW_INDEX>" >&2
  exit 2
fi
BASE=$1
CAND=$2
NEW_INDEX=$3

for f in "$BASE" "$CAND"; do
  [[ -r "$f" ]] || { echo "cannot read: $f" >&2; echo "RESULT: FAIL (unreadable: $f)"; exit 2; }
  # Fail closed on unparseable input — a malformed candidate must never pass.
  jq empty "$f" 2>/dev/null || { echo "INVALID_JSON | $f" >&2; echo "RESULT: FAIL (invalid JSON: $f)"; exit 2; }
done

PASS=()
FAIL=()

idxlist() { jq -r '.proposal.specs[]?.index' "$1" | LC_ALL=C sort; }
BASE_IDX=$(idxlist "$BASE")
CAND_IDX=$(idxlist "$CAND")

# 1) No pre-existing spec may be removed.
while IFS= read -r removed; do
  [[ -z "$removed" ]] && continue
  FAIL+=("removed-spec|$removed|pre-existing spec dropped from candidate")
done < <(comm -23 <(printf '%s\n' "$BASE_IDX") <(printf '%s\n' "$CAND_IDX"))

# 2) Exactly one spec may be added, and it must be NEW_INDEX.
ADDED=$(comm -13 <(printf '%s\n' "$BASE_IDX") <(printf '%s\n' "$CAND_IDX"))
added_count=0
saw_new=0
while IFS= read -r added; do
  [[ -z "$added" ]] && continue
  added_count=$((added_count + 1))
  if [[ "$added" == "$NEW_INDEX" ]]; then
    saw_new=1
  else
    FAIL+=("unexpected-new-spec|$added|only $NEW_INDEX may be added")
  fi
done < <(printf '%s\n' "$ADDED")
if [[ "$saw_new" -eq 1 ]]; then
  PASS+=("added|$NEW_INDEX|new testnet spec present")
else
  FAIL+=("missing-new-spec|$NEW_INDEX|expected testnet index was not added")
fi

# 3) Every pre-existing spec must be semantically identical to the base.
while IFS= read -r idx; do
  [[ -z "$idx" ]] && continue
  # skip indexes that no longer exist (already reported as removed in step 1)
  printf '%s\n' "$CAND_IDX" | grep -qxF "$idx" || continue
  b=$(jq -S -c --arg i "$idx" '.proposal.specs[] | select(.index==$i)' "$BASE")
  c=$(jq -S -c --arg i "$idx" '.proposal.specs[] | select(.index==$i)' "$CAND")
  if [[ "$b" == "$c" ]]; then
    PASS+=("preserved|$idx|pre-existing spec unchanged")
  else
    FAIL+=("modified-spec|$idx|pre-existing spec was changed (mainnet drift)")
  fi
done < <(printf '%s\n' "$BASE_IDX")

# 4) Envelope structure: top-level and .proposal key sets must not change
#    (catches a stray title/description/deposit reintroduced alongside the add).
tl_base=$(jq -S -c 'keys' "$BASE"); tl_cand=$(jq -S -c 'keys' "$CAND")
[[ "$tl_base" == "$tl_cand" ]] && PASS+=("top-level-keys|ok|unchanged") \
  || FAIL+=("top-level-keys|changed|base=$tl_base cand=$tl_cand")
pk_base=$(jq -S -c '.proposal | keys' "$BASE"); pk_cand=$(jq -S -c '.proposal | keys' "$CAND")
[[ "$pk_base" == "$pk_cand" ]] && PASS+=("proposal-keys|ok|unchanged") \
  || FAIL+=("proposal-keys|changed|base=$pk_base cand=$pk_cand")

# 5) The added spec must be a proper inheriting testnet: non-empty imports, and
#    at least one import references a spec present in the base (its mainnet).
if [[ "$saw_new" -eq 1 ]]; then
  imports=$(jq -c --arg i "$NEW_INDEX" '[.proposal.specs[] | select(.index==$i) | .imports[]?]' "$CAND")
  if [[ "$imports" == "[]" || "$imports" == "null" ]]; then
    FAIL+=("no-imports|$NEW_INDEX|testnet must import its mainnet spec")
  else
    hit=0
    while IFS= read -r imp; do
      [[ -z "$imp" ]] && continue
      printf '%s\n' "$BASE_IDX" | grep -qxF "$imp" && hit=1
    done < <(jq -r --arg i "$NEW_INDEX" '.proposal.specs[] | select(.index==$i) | .imports[]?' "$CAND")
    [[ "$hit" -eq 1 ]] && PASS+=("imports|$NEW_INDEX|inherits an existing in-file spec") \
      || FAIL+=("imports-unresolved|$NEW_INDEX|imports none of the pre-existing specs")
  fi
fi

# 6) Catch-all backstop: the candidate with the new index stripped out must be
#    canonical-identical to the base. This subsumes checks 1/3/4 AND closes two
#    gaps the itemized checks miss: a REORDERED pre-existing specs array (checks
#    3 select by index, so are order-blind), and a changed VALUE of any non-`specs`
#    envelope key (check 4 compares key SETS only). The itemized checks above stay
#    for actionable diagnostics; this is the authoritative mechanical gate.
cand_minus_new=$(jq -S --arg i "$NEW_INDEX" '.proposal.specs |= map(select(.index != $i))' "$CAND")
base_canon=$(jq -S . "$BASE")
if [[ "$cand_minus_new" == "$base_canon" ]]; then
  PASS+=("catch-all|ok|candidate minus $NEW_INDEX is canonical-identical to base")
else
  FAIL+=("catch-all|drift|candidate minus $NEW_INDEX differs from base (spec reorder or envelope change)")
fi

echo "=== PASS ==="
printf '%s\n' ${PASS[@]+"${PASS[@]}"}
echo
echo "=== FAIL ==="
printf '%s\n' ${FAIL[@]+"${FAIL[@]}"}

if [[ ${#FAIL[@]} -eq 0 ]]; then
  echo
  echo "RESULT: PASS (only $NEW_INDEX added; all pre-existing specs preserved)"
  exit 0
fi
echo
echo "RESULT: FAIL (${#FAIL[@]} violation(s))"
exit 1
