#!/usr/bin/env bash
# spec-methods-diff: check which methods a Lava chain spec serves, following imports.
#
# Usage:
#   spec-methods-diff <spec.json> <methods-file>
#   spec-methods-diff <spec.json> -          # read methods from stdin
#
# Walks .imports[] transitively. Parent specs are resolved from
# <specs-root>/{mainnet-1,testnet-2}/specs/<index-lowercased>.json, where
# <specs-root> is the nearest ancestor dir containing those subdirs.

set -euo pipefail
export LC_ALL=C

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <spec.json> <methods-file|->" >&2
  exit 2
fi

SPEC=$(realpath -- "$1")
LIST=$2
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

# Locate the specs-root (ancestor containing mainnet-1/specs or testnet-2/specs).
SEARCH=$(dirname "$SPEC")
SPECS_ROOT=""
while [[ "$SEARCH" != "/" ]]; do
  if [[ -d "$SEARCH/mainnet-1/specs" || -d "$SEARCH/testnet-2/specs" ]]; then
    SPECS_ROOT=$SEARCH; break
  fi
  SEARCH=$(dirname "$SEARCH")
done
[[ -n "$SPECS_ROOT" ]] || {
  echo "could not locate specs root above $SPEC (need mainnet-1/specs or testnet-2/specs)" >&2
  exit 1; }

file_env() {
  # Given a file path under $SPECS_ROOT/<env>/specs/, return <env>.
  printf '%s' "$1" | sed -E "s#^${SPECS_ROOT//#/\\#}/([^/]+)/specs/.*#\1#"
}

resolve_parent() {
  local idx_lower order=()
  idx_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "${2:-}" in
    testnet-2) order=(testnet-2 mainnet-1) ;;
    mainnet-1) order=(mainnet-1 testnet-2) ;;
    *)         order=(mainnet-1 testnet-2) ;;
  esac
  for d in "${order[@]}"; do
    local f="$SPECS_ROOT/$d/specs/$idx_lower.json"
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# BFS over the import graph. SEEN[index] = source file path.
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
  cur_env=$(file_env "$cur_file")
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -n "${SEEN[$p]:-}" ]] && continue
    if pf=$(resolve_parent "$p" "$cur_env"); then
      SEEN[$p]=$pf
      queue+=("$p")
    else
      echo "warn: parent spec '$p' not found under $SPECS_ROOT/{$cur_env,...}/specs/" >&2
    fi
  done < <(jq -r --arg idx "$cur" '.proposal.specs[] | select(.index == $idx) | .imports[]?' "$cur_file")
done

# Emit (iface, method, source_index) for every loaded index.
SPEC_TRIPLES=""
for idx in "${!SEEN[@]}"; do
  file=${SEEN[$idx]}
  rows=$(jq -r --arg idx "$idx" '
    .proposal.specs[] | select(.index == $idx)
    | .api_collections[]?
    | .collection_data.api_interface as $iface
    | .apis[]?.name
    | select(. != null and . != "")
    | "\($iface)\t\(.)\t\($idx)"
  ' "$file")
  [[ -n "$rows" ]] && SPEC_TRIPLES+="$rows"$'\n'
done

[[ -n "$SPEC_TRIPLES" ]] || {
  echo "error: no APIs extracted from $SPEC (or transitive imports)" >&2; exit 1; }

WANTED=$(
  { [[ "$LIST" == "-" ]] && cat || cat -- "$LIST"; } \
  | tr -d '\r' \
  | sed -E 's/#.*$//; s/[[:space:]]+$//; s/^[[:space:]]+//' \
  | awk 'NF && !seen[$0]++'
)

# Transparency: print the resolved chain before the diff.
{
  echo "Resolved spec chain (specs_root=$SPECS_ROOT):"
  for idx in "${!SEEN[@]}"; do
    echo "  $idx <- ${SEEN[$idx]}"
  done
} | sort
echo

awk -F'\t' -v wanted="$WANTED" '
  {
    key = $2
    if (key in ifaces) {
      if (index(","ifaces[key]",", ","$1",") == 0) ifaces[key] = ifaces[key] "," $1
    } else ifaces[key] = $1
    if (key in sources) {
      if (index(","sources[key]",", ","$3",") == 0) sources[key] = sources[key] "," $3
    } else sources[key] = $3
    spec_methods[key] = 1
  }
  END {
    n = split(wanted, w, "\n")
    print "=== PRESENT (interface<TAB>method<TAB>source-index) ==="
    for (i = 1; i <= n; i++) {
      m = w[i]; if (m == "") continue
      if (m in spec_methods) print ifaces[m] "\t" m "\t" sources[m]
      wanted_set[m] = 1
    }

    print ""
    print "=== MISSING (in your list, not in spec or imports) ==="
    for (i = 1; i <= n; i++) {
      m = w[i]; if (m == "" || (m in spec_methods)) continue
      print m
    }

    print ""
    print "=== EXTRA IN SPEC (not in your list) ==="
    for (m in spec_methods)
      if (!(m in wanted_set)) print m | "sort -u"
  }
' <<< "$SPEC_TRIPLES"

