#!/usr/bin/env bash
# check_collection_addition.sh — additive-only guard for the "add an api_collection
# to an existing <chain>.json" mode (add-collection).
#
# Asserts that a candidate spec file differs from its base ONLY by the addition of
# api_collections, and that everything else — every pre-existing collection, every
# spec-level field, the set of spec entries, the envelope — is semantically
# unchanged. This is the guard that makes drift IMPOSSIBLE in add-collection mode,
# the way check_preservation.sh does it for add-testnet.
#
# The two guards are deliberately different shapes and neither substitutes for the
# other:
#   check_preservation.sh  exactly one SPEC entry added, no spec changed at all.
#   this one              no spec entry added or removed; COLLECTIONS may be added
#                         to named specs, and nothing else may move.
# An add-collection PR is N/A for check_preservation.sh (it adds no index and it
# does modify a pre-existing spec), which is why it needs its own gate rather than
# shipping unguarded — the failure mode it protects against is PR #80's, where a
# regeneration silently drifted average_block_time 200->35 and a parse arg
# block_height->block_hash while looking like an ordinary edit.
#
# Comparison is on jq -S canonical form (recursive key-sort), so it is immune to
# whitespace and key order but catches every value change, field add/remove, and
# array reorder.
#
# Collections are identified by their CollectionData 4-tuple
# (api_interface, internal_path, type, add_on) — the same key the router merges on
# (x/spec/types/spec.go CombineCollections), so "the same collection" here means
# what it means at runtime.
#
# Usage:
#   check_collection_addition.sh <base.json> <candidate.json> [INDEX[,INDEX...]]
#     base.json      the pre-edit file (e.g. `git show origin/main:<chain>.json`)
#     candidate.json the file after the collections were added
#     INDEX list     optional; the spec indexes allowed to gain collections. When
#                    given, a collection appearing under any OTHER index is a
#                    violation. When omitted, any index may gain collections and
#                    the guard still enforces that nothing is modified or removed.
#
# Exit: 0 PASS · 1 FAIL (drift/structure) · 2 usage or unparseable input.
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <base.json> <candidate.json> [INDEX[,INDEX...]]" >&2
  exit 2
fi
BASE=$1
CAND=$2
ALLOWED=${3:-}

for f in "$BASE" "$CAND"; do
  [[ -r "$f" ]] || { echo "cannot read: $f" >&2; echo "RESULT: FAIL (unreadable: $f)"; exit 2; }
  # `jq empty` exits 0 on an EMPTY file (no input is not invalid input), so an empty
  # or truncated candidate would sail past and then read as "every collection removed".
  # Requiring a top-level object fails closed on empty, truncated, array and scalar
  # inputs alike — a guard that cannot parse its input must never report PASS.
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || {
    echo "INVALID_JSON | $f" >&2; echo "RESULT: FAIL (not a JSON object: $f)"; exit 2; }
done

PASS=()
FAIL=()

idxlist() { jq -r '.proposal.specs[]?.index' "$1" | LC_ALL=C sort; }
BASE_IDX=$(idxlist "$BASE")
CAND_IDX=$(idxlist "$CAND")

# 1) The set of spec entries must be identical. Adding a spec is add-testnet's job
#    and is guarded there; removing one is never right.
while IFS= read -r removed; do
  [[ -z "$removed" ]] && continue
  FAIL+=("removed-spec|$removed|pre-existing spec dropped from candidate")
done < <(comm -23 <(printf '%s\n' "$BASE_IDX") <(printf '%s\n' "$CAND_IDX"))
while IFS= read -r added; do
  [[ -z "$added" ]] && continue
  FAIL+=("added-spec|$added|add-collection must not add a spec entry — use add-testnet")
done < <(comm -13 <(printf '%s\n' "$BASE_IDX") <(printf '%s\n' "$CAND_IDX"))

# collection keys for one spec, as canonical 4-tuples
# Fields are joined with US (\x1f), not a tab: tab is an IFS *whitespace* character,
# so `IFS=$'\t' read` collapses runs of them and an empty internal_path or add_on —
# the common case — silently shifts every later field left.
collkeys() {
  jq -r --arg i "$2" '.proposal.specs[] | select(.index==$i) | .api_collections[]?
    | [.collection_data.api_interface, .collection_data.internal_path,
       .collection_data.type, .collection_data.add_on] | join("\u001f")' "$1" | LC_ALL=C sort
}
# one collection's canonical body, addressed by its 4-tuple
collbody() {
  jq -S -c --arg i "$2" --arg a "$3" --arg p "$4" --arg t "$5" --arg o "$6" \
    '.proposal.specs[] | select(.index==$i) | .api_collections[]
     | select(.collection_data.api_interface==$a and .collection_data.internal_path==$p
              and .collection_data.type==$t and .collection_data.add_on==$o)' "$1"
}

is_allowed() {
  [[ -z "$ALLOWED" ]] && return 0
  local want=$1 tok
  IFS=',' read -ra toks <<< "$ALLOWED"
  for tok in "${toks[@]}"; do [[ "$tok" == "$want" ]] && return 0; done
  return 1
}

added_total=0
while IFS= read -r idx; do
  [[ -z "$idx" ]] && continue
  printf '%s\n' "$CAND_IDX" | grep -qxF "$idx" || continue

  # 2) Every spec-level field EXCEPT api_collections must be untouched.
  b=$(jq -S -c --arg i "$idx" '.proposal.specs[] | select(.index==$i) | del(.api_collections)' "$BASE")
  c=$(jq -S -c --arg i "$idx" '.proposal.specs[] | select(.index==$i) | del(.api_collections)' "$CAND")
  if [[ "$b" == "$c" ]]; then
    PASS+=("spec-fields|$idx|unchanged outside api_collections")
  else
    FAIL+=("modified-spec-fields|$idx|a spec-level field changed (drift)")
  fi

  # 3) No pre-existing collection may be removed, and each must be byte-identical.
  while IFS=$'\037' read -r a p t o; do
    [[ -z "${a:-}" && -z "${p:-}" && -z "${t:-}" && -z "${o:-}" ]] && continue
    key="$a|$p|$t|$o"
    cb=$(collbody "$CAND" "$idx" "$a" "$p" "$t" "$o")
    if [[ -z "$cb" ]]; then
      FAIL+=("removed-collection|$idx|$key|pre-existing collection dropped")
      continue
    fi
    bb=$(collbody "$BASE" "$idx" "$a" "$p" "$t" "$o")
    if [[ "$bb" == "$cb" ]]; then
      PASS+=("preserved-collection|$idx|$key")
    else
      FAIL+=("modified-collection|$idx|$key|pre-existing collection was changed")
    fi
  done < <(collkeys "$BASE" "$idx")

  # 4) Collections that are new under this index.
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    added_total=$((added_total + 1))
    if is_allowed "$idx"; then
      PASS+=("added-collection|$idx|${key//$'\037'/|}")
    else
      FAIL+=("unexpected-collection|$idx|${key//$'\037'/|}|only [$ALLOWED] may gain collections")
    fi
  done < <(comm -13 <(collkeys "$BASE" "$idx") <(collkeys "$CAND" "$idx"))
done < <(printf '%s\n' "$BASE_IDX")

# 5) Something must actually have been added — a no-op is a mis-invocation, not a pass.
if [[ "$added_total" -eq 0 ]]; then
  FAIL+=("no-collection-added|-|candidate adds no collection; nothing to guard")
fi

# 6) Envelope: top-level and .proposal key sets must not change.
tl_base=$(jq -S -c 'keys' "$BASE"); tl_cand=$(jq -S -c 'keys' "$CAND")
[[ "$tl_base" == "$tl_cand" ]] && PASS+=("top-level-keys|ok|unchanged") \
  || FAIL+=("top-level-keys|changed|base=$tl_base cand=$tl_cand")
pk_base=$(jq -S -c '.proposal | keys' "$BASE"); pk_cand=$(jq -S -c '.proposal | keys' "$CAND")
[[ "$pk_base" == "$pk_cand" ]] && PASS+=("proposal-keys|ok|unchanged") \
  || FAIL+=("proposal-keys|changed|base=$pk_base cand=$pk_cand")

# 7) Catch-all backstop: strip every ADDED collection from the candidate and the
#    result must be canonical-identical to the base. This subsumes 1/2/3/6 and also
#    closes what they miss — a reordered specs array (2 and 3 select by index, so
#    they are order-blind) and a changed VALUE of any non-`specs` envelope key
#    (6 compares key SETS only). The itemized checks stay for actionable
#    diagnostics; this is the authoritative mechanical gate.
stripped=$(jq -S --slurpfile b "$BASE" '
  ($b[0].proposal.specs
     | map({key: .index, value: [.api_collections[]? | .collection_data]})
     | from_entries) as $basekeys
  | .proposal.specs |= map(
      .index as $i
      | ($basekeys[$i] // []) as $known
      | .api_collections = [ .api_collections[]? as $c
          | select($known | any(. == $c.collection_data))
          | $c ]
    )' "$CAND")
base_canon=$(jq -S . "$BASE")
if [[ "$stripped" == "$base_canon" ]]; then
  PASS+=("catch-all|ok|candidate minus added collections is canonical-identical to base")
else
  FAIL+=("catch-all|drift|candidate minus added collections differs from base (spec reorder or envelope change)")
fi

echo "=== PASS ==="
printf '%s\n' ${PASS[@]+"${PASS[@]}"}
echo
echo "=== FAIL ==="
printf '%s\n' ${FAIL[@]+"${FAIL[@]}"}

if [[ ${#FAIL[@]} -eq 0 ]]; then
  echo
  echo "RESULT: PASS ($added_total collection(s) added; everything else preserved)"
  exit 0
fi
echo
echo "RESULT: FAIL (${#FAIL[@]} violation(s))"
exit 1
