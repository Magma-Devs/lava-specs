#!/usr/bin/env bash
# spec-methods-diff: check which methods a Lava chain spec serves, following imports.
#
# Usage:
#   spec-methods-diff <spec.json> <methods-file>
#   spec-methods-diff <spec.json> -          # read methods from stdin
#
# Walks .imports[] transitively. This repo is flat: every spec is a *.json at
# the repo root. Parent specs are resolved by CONTENT, not filename — every
# *.json beside the candidate is scanned and imports are matched to whichever
# file declares that index (e.g. ETH1 lives in ethereum.json, not eth1.json).

set -euo pipefail
export LC_ALL=C

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <spec.json> <methods-file|->" >&2
  exit 2
fi

SPEC=$(realpath -- "$1")
LIST=$2
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

# Resolve parent specs by CONTENT, not filename: a spec file may hold several
# indexes (e.g. ethereum.json holds ETH1, SEP1, HOL1) and is not named after any
# of them. Build an index -> file map by scanning every *.json beside the
# candidate (the flat repo root). First registration wins.
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

# Flat repo: all specs live beside the candidate. Scan that one directory.
register_dir "$(dirname "$SPEC")"

resolve_parent() {  # $1 = index -> prints source file path, or fails
  local f=${INDEX_FILE[$1]:-}
  [[ -n "$f" ]] && { printf '%s\n' "$f"; return 0; }
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
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -n "${SEEN[$p]:-}" ]] && continue
    if pf=$(resolve_parent "$p"); then
      SEEN[$p]=$pf
      queue+=("$p")
    else
      echo "warn: parent spec '$p' not found in any spec file at the repo root" >&2
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
  echo "Resolved spec chain (by index content):"
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

