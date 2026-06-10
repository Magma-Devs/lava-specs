#!/usr/bin/env bash
# compare_spec.sh — compare a candidate Lava chain spec against a gold reference
# and score it using the eval-lava-spec rubric.
#
# Usage:
#   scripts/compare_spec.sh <candidate.json> <gold.json> [SPEC_INDEX]
#
# Examples:
#   scripts/compare_spec.sh specs/testnet-2/specs/iota.json /tmp/iota.gold.json
#   scripts/compare_spec.sh specs/testnet-2/specs/xrp.json /tmp/ripple.gold.json XRP
#
# If SPEC_INDEX is omitted, the script uses the first spec entry from the gold.
#
# Depends on: jq, bash.

set -euo pipefail

# ---------- args ----------

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <candidate.json> <gold.json> [SPEC_INDEX]" >&2
  exit 1
fi

CAND="$1"
GOLD="$2"
INDEX="${3:-}"

for f in "$CAND" "$GOLD"; do
  [ -f "$f" ] || { echo "error: $f not found" >&2; exit 1; }
  jq empty "$f" 2>/dev/null || { echo "error: $f is not valid JSON" >&2; exit 1; }
done

if [ -z "$INDEX" ]; then
  INDEX=$(jq -r '.proposal.specs[0].index' "$GOLD")
fi

# ---------- helpers ----------

# Extract method names for a given spec index across all collections.
methods() {
  jq -r --arg idx "$1" '.proposal.specs[] | select(.index == $idx)
    | .api_collections[]?.apis[]?.name' "$2" | sort -u
}

# Extract (function_tag, api_name) pairs for parse_directives.
directives() {
  jq -r --arg idx "$1" '.proposal.specs[] | select(.index == $idx)
    | .api_collections[]?.parse_directives[]?
    | "\(.function_tag)|\(.api_name // "")"' "$2" | sort -u
}

# Extract verifications by name. Returns lines: <verification_name>|<first_expected_value>
verifications() {
  jq -r --arg idx "$1" '.proposal.specs[] | select(.index == $idx)
    | .api_collections[]?.verifications[]?
    | "\(.name)|\(.values[0]?.expected_value // "")"' "$2"
}

# Extract extensions: <name>|<cu_multiplier>|<rule.block>
extensions() {
  jq -r --arg idx "$1" '.proposal.specs[] | select(.index == $idx)
    | .api_collections[]?.extensions[]?
    | "\(.name)|\(.cu_multiplier // "")|\(.rule.block // "")"' "$2"
}

# Extract network-param tuple: block_time|fin_dist|fin_proof|qos_lag
network_params() {
  jq -r --arg idx "$1" '.proposal.specs[] | select(.index == $idx)
    | "\(.average_block_time)|\(.block_distance_for_finalized_data)|\(.blocks_in_finalization_proof)|\(.allowed_block_lag_for_qos_sync)"' "$2"
}

# Map a 0-100 score to a letter grade.
grade_for() {
  local n="$1"
  if   [ "$n" -ge 95 ]; then echo "A++"
  elif [ "$n" -ge 90 ]; then echo "A+"
  elif [ "$n" -ge 85 ]; then echo "A"
  elif [ "$n" -ge 80 ]; then echo "A-"
  elif [ "$n" -ge 75 ]; then echo "B++"
  elif [ "$n" -ge 70 ]; then echo "B+"
  elif [ "$n" -ge 65 ]; then echo "B"
  elif [ "$n" -ge 60 ]; then echo "B-"
  elif [ "$n" -ge 50 ]; then echo "C+"
  elif [ "$n" -ge 40 ]; then echo "C"
  elif [ "$n" -ge 30 ]; then echo "D"
  elif [ "$n" -ge 20 ]; then echo "E"
  else                       echo "E--"
  fi
}

# Floating-point arithmetic via awk.
calc() { awk "BEGIN { printf \"%.2f\", $1 }"; }
round() { awk "BEGIN { printf \"%d\", ($1) + 0.5 }"; }

# ---------- header ----------

echo "=== Spec comparison ==="
echo "Candidate: $CAND"
echo "Gold:      $GOLD"
echo "Index:     $INDEX"
echo ""

# ---------- category 3: chain metadata (20%) ----------

CAND_NP=$(network_params "$INDEX" "$CAND")
GOLD_NP=$(network_params "$INDEX" "$GOLD")

IFS='|' read -r CAND_BT CAND_FD CAND_FP CAND_QL <<< "$CAND_NP"
IFS='|' read -r GOLD_BT GOLD_FD GOLD_FP GOLD_QL <<< "$GOLD_NP"

echo "=== Network params (chain_metadata, weight 20%) ==="
printf "  %-35s %-12s %-12s %s\n" "field" "candidate" "gold" "match"
META_MATCH=0
for pair in "average_block_time|$CAND_BT|$GOLD_BT" \
            "block_distance_for_finalized_data|$CAND_FD|$GOLD_FD" \
            "blocks_in_finalization_proof|$CAND_FP|$GOLD_FP" \
            "allowed_block_lag_for_qos_sync|$CAND_QL|$GOLD_QL"; do
  IFS='|' read -r FIELD CV GV <<< "$pair"
  if [ "$CV" = "$GV" ]; then
    MARK="✓"; META_MATCH=$((META_MATCH+1))
  else
    MARK="✗"
  fi
  printf "  %-35s %-12s %-12s %s\n" "$FIELD" "$CV" "$GV" "$MARK"
done
META_SCORE=$(round "$META_MATCH/4*100")
echo "  → ${META_MATCH}/4 fields match → ${META_SCORE}/100"
echo ""

# ---------- category 2: method coverage (25%) ----------

methods "$INDEX" "$CAND" > /tmp/.spec_cmp_cand_m.$$
methods "$INDEX" "$GOLD" > /tmp/.spec_cmp_gold_m.$$

CAND_COUNT=$(wc -l < /tmp/.spec_cmp_cand_m.$$)
GOLD_COUNT=$(wc -l < /tmp/.spec_cmp_gold_m.$$)
INTERSECT_COUNT=$(comm -12 /tmp/.spec_cmp_cand_m.$$ /tmp/.spec_cmp_gold_m.$$ | wc -l)
MISSED=$(comm -23 /tmp/.spec_cmp_gold_m.$$ /tmp/.spec_cmp_cand_m.$$)
EXTRA=$(comm -13 /tmp/.spec_cmp_gold_m.$$ /tmp/.spec_cmp_cand_m.$$)
MISSED_COUNT=$(printf '%s\n' "$MISSED" | grep -c . || true)
EXTRA_COUNT=$(printf '%s\n' "$EXTRA" | grep -c . || true)

echo "=== Methods (method_coverage, weight 25%) ==="
echo "  gold count:    $GOLD_COUNT"
echo "  candidate count: $CAND_COUNT"
echo "  intersection:  $INTERSECT_COUNT"

if [ "$MISSED_COUNT" -gt 0 ]; then
  echo "  missing from candidate ($MISSED_COUNT):"
  echo "$MISSED" | sed 's/^/    - /'
fi
if [ "$EXTRA_COUNT" -gt 0 ]; then
  echo "  extra in candidate ($EXTRA_COUNT) — assumed verified per rubric:"
  echo "$EXTRA" | sed 's/^/    + /'
fi

if [ "$GOLD_COUNT" -gt 0 ]; then
  RECALL=$(calc "$INTERSECT_COUNT/$GOLD_COUNT")
else
  RECALL="1.00"
fi
if [ "$CAND_COUNT" -gt 0 ]; then
  PRECISION=$(calc "($INTERSECT_COUNT + $EXTRA_COUNT) / $CAND_COUNT")
else
  PRECISION="1.00"
fi
# clamp precision to 1
PRECISION=$(awk "BEGIN { p = $PRECISION; if (p > 1) p = 1; printf \"%.2f\", p }")
METHOD_SCORE=$(round "($RECALL * 0.70 + $PRECISION * 0.30) * 100")
echo "  recall: $RECALL    precision: $PRECISION"
echo "  → ${METHOD_SCORE}/100"
echo ""

# ---------- category 1: parse directives (25%) ----------

directives "$INDEX" "$CAND" > /tmp/.spec_cmp_cand_d.$$
directives "$INDEX" "$GOLD" > /tmp/.spec_cmp_gold_d.$$

GOLD_DIR_COUNT=$(wc -l < /tmp/.spec_cmp_gold_d.$$)
DIR_MATCHED=$(comm -12 /tmp/.spec_cmp_cand_d.$$ /tmp/.spec_cmp_gold_d.$$ | wc -l)

echo "=== Parse directives (parse_directives, weight 25%) ==="
printf "  %-25s %-40s %-40s %s\n" "function_tag" "candidate api_name" "gold api_name" "match"
# Iterate over the union of (function_tag, api_name) tuples so multi-entry tags
# (e.g., SUBSCRIBE × 2) each get their own row.
ALL_ENTRIES=$(cat /tmp/.spec_cmp_cand_d.$$ /tmp/.spec_cmp_gold_d.$$ | sort -u)
while IFS='|' read -r TAG API; do
  [ -z "$TAG" ] && continue
  if grep -Fxq "${TAG}|${API}" /tmp/.spec_cmp_cand_d.$$; then IN_CAND=1; else IN_CAND=0; fi
  if grep -Fxq "${TAG}|${API}" /tmp/.spec_cmp_gold_d.$$; then IN_GOLD=1; else IN_GOLD=0; fi
  if [ "$IN_CAND" = 1 ] && [ "$IN_GOLD" = 1 ]; then
    MARK="✓"
    C_DISP="$API"; G_DISP="$API"
  elif [ "$IN_CAND" = 1 ]; then
    MARK="✗ (extra)"
    C_DISP="$API"; G_DISP="—"
  else
    MARK="✗ (missing)"
    C_DISP="—"; G_DISP="$API"
  fi
  printf "  %-25s %-40s %-40s %s\n" "$TAG" "$C_DISP" "$G_DISP" "$MARK"
done <<< "$ALL_ENTRIES"

if [ "$GOLD_DIR_COUNT" -gt 0 ]; then
  DIR_SCORE=$(round "$DIR_MATCHED/$GOLD_DIR_COUNT*100")
else
  if [ "$(wc -l < /tmp/.spec_cmp_cand_d.$$)" -eq 0 ]; then
    DIR_SCORE=100
  else
    DIR_SCORE=0
  fi
fi
echo "  → ${DIR_MATCHED}/${GOLD_DIR_COUNT} matched → ${DIR_SCORE}/100"
echo ""

# ---------- category 4: verifications (15%) ----------

verifications "$INDEX" "$CAND" > /tmp/.spec_cmp_cand_v.$$
verifications "$INDEX" "$GOLD" > /tmp/.spec_cmp_gold_v.$$

echo "=== Verifications (verifications, weight 15%) ==="
# Per rubric: count chain-id (each entry) + pruning if in upstream.
COUNTED_TYPES="chain-id|pruning"
EXPECTED=0
MATCHED=0
for TYPE in $(echo "$COUNTED_TYPES" | tr '|' '\n'); do
  while IFS='|' read -r NAME VAL; do
    [ "$NAME" = "$TYPE" ] || continue
    EXPECTED=$((EXPECTED+1))
    if grep -Fxq "${NAME}|${VAL}" /tmp/.spec_cmp_cand_v.$$; then
      MATCHED=$((MATCHED+1))
      printf "  %-30s cand=%-15s gold=%-15s ✓\n" "$NAME" "$VAL" "$VAL"
    else
      CAND_VAL=$(grep "^${NAME}|" /tmp/.spec_cmp_cand_v.$$ 2>/dev/null | head -1 | cut -d'|' -f2- || true)
      printf "  %-30s cand=%-15s gold=%-15s ✗\n" "$NAME" "${CAND_VAL:--}" "$VAL"
    fi
  done < /tmp/.spec_cmp_gold_v.$$
done

# Note any extra verifications in candidate (not counted by rubric but worth flagging).
EXTRA_VERS=$(comm -23 \
  <(cut -d'|' -f1 /tmp/.spec_cmp_cand_v.$$ | sort -u) \
  <(cut -d'|' -f1 /tmp/.spec_cmp_gold_v.$$ | sort -u))
if [ -n "$EXTRA_VERS" ]; then
  echo "  extra in candidate (not penalized by rubric):"
  echo "$EXTRA_VERS" | sed 's/^/    + /'
fi
# Note any uncounted-but-present-in-gold verification types (e.g., tracking-shard)
UNCOUNTED_GOLD=$(comm -23 \
  <(cut -d'|' -f1 /tmp/.spec_cmp_gold_v.$$ | sort -u) \
  <(echo "chain-id"; echo "pruning"))
if [ -n "$UNCOUNTED_GOLD" ]; then
  echo "  in gold but not rubric-counted (real defects if missing — review manually):"
  echo "$UNCOUNTED_GOLD" | sed 's/^/    ! /'
fi

if [ "$EXPECTED" -gt 0 ]; then
  VER_SCORE=$(round "$MATCHED/$EXPECTED*100")
else
  if [ "$(wc -l < /tmp/.spec_cmp_cand_v.$$)" -eq 0 ]; then
    VER_SCORE=100
  else
    VER_SCORE=0
  fi
fi
echo "  → ${MATCHED}/${EXPECTED} matched → ${VER_SCORE}/100"
echo ""

# ---------- category 5: plugins / extensions (15%) ----------

extensions "$INDEX" "$CAND" > /tmp/.spec_cmp_cand_e.$$
extensions "$INDEX" "$GOLD" > /tmp/.spec_cmp_gold_e.$$

# add_on list
CAND_ADDONS=$(jq -r --arg idx "$INDEX" '.proposal.specs[] | select(.index == $idx)
  | .api_collections[]? | .collection_data.add_on // "" | select(. != "")' "$CAND" | sort -u)
GOLD_ADDONS=$(jq -r --arg idx "$INDEX" '.proposal.specs[] | select(.index == $idx)
  | .api_collections[]? | .collection_data.add_on // "" | select(. != "")' "$GOLD" | sort -u)

echo "=== Plugins / extensions (weight 15%) ==="
echo "  add_ons (cand): ${CAND_ADDONS:-<none>}"
echo "  add_ons (gold): ${GOLD_ADDONS:-<none>}"
echo ""
echo "  extensions:"
printf "    %-12s %-15s %-15s %s\n" "name" "candidate" "gold" "match"
EXT_GOLD_COUNT=$(wc -l < /tmp/.spec_cmp_gold_e.$$)
EXT_MATCHED=0
EXT_NAMES=$(cat /tmp/.spec_cmp_cand_e.$$ /tmp/.spec_cmp_gold_e.$$ | cut -d'|' -f1 | sort -u)
for NAME in $EXT_NAMES; do
  [ -z "$NAME" ] && continue
  C_LINE=$(grep "^${NAME}|" /tmp/.spec_cmp_cand_e.$$ 2>/dev/null | head -1 || true)
  G_LINE=$(grep "^${NAME}|" /tmp/.spec_cmp_gold_e.$$ 2>/dev/null | head -1 || true)
  if [ -n "$C_LINE" ] && [ -n "$G_LINE" ] && [ "$C_LINE" = "$G_LINE" ]; then
    EXT_MATCHED=$((EXT_MATCHED+1))
    MARK="✓"
  elif [ -n "$C_LINE" ] && [ -n "$G_LINE" ]; then
    MARK="~ partial (params differ)"
  else
    MARK="✗"
  fi
  C_DISP=${C_LINE#${NAME}|}
  G_DISP=${G_LINE#${NAME}|}
  printf "    %-12s %-15s %-15s %s\n" "$NAME" "${C_DISP:-<none>}" "${G_DISP:-<none>}" "$MARK"
done

# Score: F1-ish — strict exact-match on extensions per rubric.
ADDON_GOLD_COUNT=$(printf '%s\n' "$GOLD_ADDONS" | grep -c . || true)
ADDON_CAND_COUNT=$(printf '%s\n' "$CAND_ADDONS" | grep -c . || true)
ADDON_MATCHED=$(comm -12 <(printf '%s\n' "$GOLD_ADDONS" | sort) <(printf '%s\n' "$CAND_ADDONS" | sort) | grep -c . || true)
TOTAL_ITEMS=$((EXT_GOLD_COUNT + ADDON_GOLD_COUNT))
TOTAL_MATCHED=$((EXT_MATCHED + ADDON_MATCHED))
if [ "$TOTAL_ITEMS" -eq 0 ] && [ "$ADDON_CAND_COUNT" -eq 0 ] && [ "$(wc -l < /tmp/.spec_cmp_cand_e.$$)" -eq 0 ]; then
  PLUGIN_SCORE=100
elif [ "$TOTAL_ITEMS" -eq 0 ]; then
  PLUGIN_SCORE=0
else
  PLUGIN_SCORE=$(round "$TOTAL_MATCHED/$TOTAL_ITEMS*100")
fi
echo "  → ${TOTAL_MATCHED}/${TOTAL_ITEMS} matched → ${PLUGIN_SCORE}/100"
echo ""

# ---------- weighted total ----------

WEIGHTED=$(calc "$DIR_SCORE*0.25 + $METHOD_SCORE*0.25 + $META_SCORE*0.20 + $VER_SCORE*0.15 + $PLUGIN_SCORE*0.15")
FINAL=$(round "$WEIGHTED")
GRADE=$(grade_for "$FINAL")

echo "=== Score breakdown ==="
printf "  %-25s %5d  ×  0.25  =  %s\n" "parse_directives"   "$DIR_SCORE"    "$(calc "$DIR_SCORE*0.25")"
printf "  %-25s %5d  ×  0.25  =  %s\n" "method_coverage"    "$METHOD_SCORE" "$(calc "$METHOD_SCORE*0.25")"
printf "  %-25s %5d  ×  0.20  =  %s\n" "chain_metadata"     "$META_SCORE"   "$(calc "$META_SCORE*0.20")"
printf "  %-25s %5d  ×  0.15  =  %s\n" "verifications"      "$VER_SCORE"    "$(calc "$VER_SCORE*0.15")"
printf "  %-25s %5d  ×  0.15  =  %s\n" "plugins_extensions" "$PLUGIN_SCORE" "$(calc "$PLUGIN_SCORE*0.15")"
echo "                                       --------"
printf "  Final: %d / 100   Grade: %s\n" "$FINAL" "$GRADE"

# ---------- cleanup ----------
rm -f /tmp/.spec_cmp_*.$$
