#!/usr/bin/env bash
# check_add_collection_pr.sh — spec_pipeline.yml's add-collection guard around the
# Phase-10 fix pass. Run from a spec PR's checkout, in two steps:
#
#   classify   BEFORE the agent runs. Decides whether the PR is an add-collection
#              PR and, if it is, prints the rule its fix pass is held to, as
#              key=value lines for $GITHUB_OUTPUT (notes go to stderr).
#   enforce    AFTER the fix pass, before the commit step. Refuses the commit when
#              the fix pass changed anything the rule does not allow.
#
# The rule. An add-collection PR (create_spec.yml's add_collection mode, or a hand
# PR of the same shape) adds api_collections for an interface — REST beside
# jsonrpc, say — to specs that already exist. Its fix pass may change only
# collections that are
#   - of an api_interface the PR's first commit added, and
#   - not on main under that index (keyed by the CollectionData 4-tuple, the key
#     the router merges on), and
#   - under an index the first commit targeted, or under an index that imports
#     one of those, transitively.
# The importers are in because a collection added to an imported spec leaks into
# every importer, carrying the parent's network values. Each importer then needs
# a collection of its own with the same key: a disabled stub, or an override of
# the inherited verifications. PR #145 (REST on BTC) needed both (DOGE's stub,
# BCH's chain-id), in btc.json and in the importers' own files. Adding a
# collection of ANOTHER interface under an existing index would rewrite what the
# index inherits for it (a child's collection absorbs the parent's of the same
# key), so it is outside the rule. So is every spec-level field, every
# collection on main, every other spec and the envelope.
#
# Anchors:
#   - classify reads the PR's FIRST commit, and its own root-JSON files, not the
#     PR's current file list: a later commit cannot change what kind of PR this is.
#   - enforce judges only what THIS run would push: the pre-agent head (START)
#     against the working tree, the way the commit step pushes it. A change that
#     is already committed — a maintainer's deliberate edit — never blocks a later
#     run; it is reported as a warning.
#   - main means the merge-base, not main's tip: a later merge to main that touched
#     the same file is not this PR's change.
#
# Usage:
#   BASE_REF=origin/main HEAD_REF_NAME=<branch> PR_TITLE=<title> \
#     check_add_collection_pr.sh classify
#   BASE=<sha> START=<sha> ALLOWED_INDEXES=A,B ADDED_IFACES=rest \
#     check_add_collection_pr.sh enforce
#
# Exit: 0 pass or N/A · 1 refused · 2 usage or unusable input.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
CCA="${CCA:-$HERE/check_collection_addition.sh}"
ROOT_JSON=':(glob)*.json'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

note() { printf '%s\n' "$*" >&2; }

# The catalog at <rev> as one JSON object: index -> {file, imports, keys}, where
# keys are the CollectionData of every collection the index declares.
catalog() {
  local rev=$1 f
  git ls-tree --name-only "$rev" | { grep -E '^[^/]+\.json$' || true; } | while IFS= read -r f; do
    git show "$rev:$f" 2>/dev/null | jq -c --arg f "$f" '
      [ .proposal.specs[]? | {key: .index, value: {file: $f, imports: (.imports // []),
                                                  keys: [.api_collections[]?.collection_data]}} ]
      | from_entries' 2>/dev/null || true
  done | jq -s -c 'add // {}'
}

# Drops what the rule allows to change: under an allowed index, every collection
# of an added interface whose key is not in the merge-base catalog. What is left
# must not move.
MASK='
  ($allowed | split(",")) as $A | ($ifaces | split(",")) as $I
  | .proposal.specs |= ((. // []) | map(
      . as $s
      | if ($A | index($s.index)) then
          .api_collections = [ (.api_collections // [])[] as $c
            | select((($base[$s.index].keys // []) | any(. == $c.collection_data))
                     or (($I | index($c.collection_data.api_interface)) | not))
            | $c ]
        else . end))'

# What differs between two masked docs, one line per finding.
DELTA='
  def keyof: .collection_data | [.api_interface, .internal_path, .type, .add_on] | join("|");
  def specs: [.proposal.specs[]? | {key: .index, value: .}] | from_entries;
  ($a | specs) as $sa | ($b | specs) as $sb
  | ([($sa | keys[]), ($sb | keys[])] | unique[]) as $i
  | if ($sa[$i] == null) then "spec-added|\($i)"
    elif ($sb[$i] == null) then "spec-removed|\($i)"
    else
      (if ($sa[$i] | del(.api_collections)) != ($sb[$i] | del(.api_collections))
       then "spec-fields|\($i)" else empty end),
      ( ([$sa[$i].api_collections[]? | {key: keyof, value: .}] | from_entries) as $ca
      | ([$sb[$i].api_collections[]? | {key: keyof, value: .}] | from_entries) as $cb
      | ([($ca | keys[]), ($cb | keys[])] | unique[]) as $k
      | if $ca[$k] == null then "collection-added|\($i)|\($k)"
        elif $cb[$k] == null then "collection-removed|\($i)|\($k)"
        elif $ca[$k] != $cb[$k] then "collection-changed|\($i)|\($k)"
        else empty end )
    end,
  (if ($a | del(.proposal.specs)) != ($b | del(.proposal.specs)) then "envelope" else empty end)'

mask() {  # <file> -> canonical masked JSON on stdout
  jq -S -c --argjson base "$BASECAT" --arg allowed "$ALLOWED_INDEXES" --arg ifaces "$ADDED_IFACES" "$MASK" "$1"
}

classify() {
  local base_ref="${BASE_REF:-origin/main}" start base first f added idx tmp="$WORK"
  out() { printf '%s=%s\n' "$1" "$2"; }
  na() {
    note "::notice::add-collection guard N/A — $1"
    out ENFORCE false
    out REASON "$1"
    exit 0
  }
  start="$(git rev-parse HEAD)"
  base="$(git merge-base "$base_ref" "$start" 2>/dev/null)" \
    || { note "::error::no merge-base between $base_ref and HEAD — cannot classify the PR."; exit 2; }

  # An update-mode PR may correct spec fields by design (phase1b-update.md). Its
  # first commit can look like an addition when all it adds is an addon
  # collection, so the name create_spec.yml gives it decides first.
  if [[ "${HEAD_REF_NAME:-}" =~ -spec-update(-[0-9]{2}-[0-9]{2}-[0-9]{4})?$ ]] \
     || [[ "${PR_TITLE:-}" == "feat(spec): update "* ]]; then
    na "an update-mode PR (by its branch or title), whose fix pass may correct fields"
  fi

  # --first-parent and no `| head -1`: a merge from main keeps the original first
  # commit first, and a SIGPIPE'd rev-list would kill the step under pipefail.
  first="$(git rev-list --reverse --first-parent "$base..$start")"
  first="${first%%$'\n'*}"
  [ -n "$first" ] || na "the branch has no commits past main"

  local files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(git diff --name-only "$first^" "$first" -- "$ROOT_JSON")
  [ "${#files[@]}" -gt 0 ] || na "the PR's first commit changes no root spec file"

  local targets="" ifaces=""
  for f in "${files[@]}"; do
    git show "$first^:$f" > "$tmp/before.json" 2>/dev/null || na "$f is new in the first commit (a new-chain PR)"
    git show "$first:$f" > "$tmp/after.json" 2>/dev/null || na "the first commit deletes $f"
    added="$(jq -c -n --slurpfile b "$tmp/before.json" --slurpfile a "$tmp/after.json" '
        ($b[0].proposal.specs // [] | map({key: .index, value: [.api_collections[]?.collection_data]})
         | from_entries) as $known
        | [ $a[0].proposal.specs[]? | select(.index as $i | $known | has($i))
            | . as $s | ([.api_collections[]?.collection_data] - $known[$s.index]) as $new
            | select($new | length > 0)
            | {index: $s.index, ifaces: [$new[].api_interface]} ]' 2>/dev/null)" \
      || na "$f does not parse at the first commit"
    idx="$(jq -r 'map(.index) | join(",")' <<<"$added")"
    [ -n "$idx" ] || na "$f: the first commit adds no collection to an existing spec"
    bash "$CCA" "$tmp/before.json" "$tmp/after.json" "$idx" >/dev/null 2>&1 \
      || na "$f: the first commit changes more than it adds (an update, add-testnet or mixed PR)"
    targets="${targets:+$targets,}$idx"
    ifaces="${ifaces:+$ifaces,}$(jq -r 'map(.ifaces[]) | join(",")' <<<"$added")"
  done
  targets="$(tr ',' '\n' <<<"$targets" | sort -u | paste -sd, -)"
  ifaces="$(tr ',' '\n' <<<"$ifaces" | sort -u | paste -sd, -)"

  # Allowed = the targets and everything that imports them, transitively, read
  # from the pre-agent head so the agent cannot widen it by adding an import.
  local cat allowed importers files_allowed
  cat="$(catalog "$start")"
  allowed="$(jq -r -n --argjson cat "$cat" --arg t "$targets" '
      [ $cat | to_entries[] | {child: .key, parents: .value.imports} ] as $edges
      | def grow($set):
          ([ $edges[] | select(any(.parents[]; . as $p | $set | index($p))) | .child ] + $set | unique) as $next
          | if ($next | length) == ($set | length) then $set else grow($next) end;
        grow($t | split(",") | unique) | join(",")')"
  importers="$(comm -13 <(tr ',' '\n' <<<"$targets" | sort) <(tr ',' '\n' <<<"$allowed" | sort) | paste -sd, -)"
  files_allowed="$(jq -r -n --argjson cat "$cat" --arg a "$allowed" \
      '[ ($a | split(","))[] as $i | $cat[$i].file // empty ] | unique | join(",")')"

  local rule="- ADD-COLLECTION PR (a guard enforces this): the Phase-10 fix pass may change ONLY api_collections whose api_interface is ${ifaces//,/ or } and that are not on main — the ones this PR added on ${targets}"
  if [ -n "$importers" ]; then
    rule+=", plus, on the specs that import them (${importers}), a collection of that kind only where the import leaks the new one with the wrong values (a disabled stub, or an override of the inherited verifications), in that spec's own file"
  fi
  rule+=". Do not change any spec-level field, any collection that is on main, any collection of another interface, or any other spec: report such findings instead of fixing them. The guard refuses the whole commit otherwise."

  note "::notice::add-collection guard ENFORCING — interface(s) ${ifaces} on ${targets}${importers:+, importers ${importers}}, first commit ${first:0:7}"
  out ENFORCE true
  out BASE "$base"
  out START "$start"
  out FIRST "$first"
  out TARGETS "$targets"
  out ALLOWED_INDEXES "$allowed"
  out ADDED_IFACES "$ifaces"
  out ALLOWED_FILES "$files_allowed"
  out PROMPT_RULE "$rule"
}

enforce() {
  : "${BASE:?BASE is required}" "${START:?START is required}"
  : "${ALLOWED_INDEXES:?ALLOWED_INDEXES is required}" "${ADDED_IFACES:?ADDED_IFACES is required}"
  git cat-file -e "$START^{commit}" 2>/dev/null || { note "::error::START $START is not a commit here."; exit 2; }
  BASECAT="$(catalog "$BASE")"

  local tmp="$WORK" f a b refused=0

  # Drift the branch already carries is not this run's, and never blocks it. It
  # is said, once, so nobody reads a pass as "the branch is clean".
  local drift=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! git show "$BASE:$f" > "$tmp/x.json" 2>/dev/null; then drift+=("$f (new)"); continue; fi
    git show "$START:$f" > "$tmp/y.json" 2>/dev/null || { drift+=("$f (deleted)"); continue; }
    a="$(mask "$tmp/x.json" 2>/dev/null)" || { drift+=("$f"); continue; }
    b="$(mask "$tmp/y.json" 2>/dev/null)" || { drift+=("$f"); continue; }
    [ "$a" = "$b" ] || drift+=("$f")
  done < <(git diff --name-only "$BASE" "$START" -- "$ROOT_JSON")
  if [ "${#drift[@]}" -gt 0 ]; then
    note "::warning::the branch already carries committed changes outside the collections this PR may change: ${drift[*]}. Not this run's, so not refused."
  fi

  # Mirror the commit step: it commits and pushes only when a tracked root JSON
  # differs from the index, and then pushes every commit since START plus every
  # root JSON, untracked ones included.
  if git diff --quiet -- "$ROOT_JSON"; then
    note "::notice::add-collection guard: nothing to commit, so there is nothing to judge."
    exit 0
  fi

  local changed=()
  while IFS= read -r f; do
    [ -n "$f" ] && changed+=("$f")
  done < <( { git diff --name-only "$START" -- "$ROOT_JSON"; git ls-files --others --exclude-standard -- "$ROOT_JSON"; } | sort -u )

  for f in "${changed[@]}"; do
    if ! git show "$START:$f" > "$tmp/start.json" 2>/dev/null; then
      note "::error::the fix pass created '$f'; an add-collection PR adds collections, not spec files."
      refused=1; continue
    fi
    if [ ! -f "$f" ]; then
      note "::error::the fix pass deleted '$f'."
      refused=1; continue
    fi
    if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      note "::error::'$f' does not parse after the fix pass."
      refused=1; continue
    fi
    a="$(mask "$tmp/start.json")"
    b="$(mask "$f")"
    if [ "$a" != "$b" ]; then
      refused=1
      note "::error::the fix pass changed '$f' outside what this add-collection PR may change:"
      jq -r -n --argjson a "$a" --argjson b "$b" "$DELTA" | sed 's/^/    /' >&2
    fi
  done

  if [ "$refused" -ne 0 ]; then
    note "Allowed: collections of interface(s) ${ADDED_IFACES} that are not on main, under ${ALLOWED_INDEXES}. Refusing to commit."
    note "A change the PR really needs goes in as its own commit, by hand. A committed change is not judged again."
    exit 1
  fi
  note "::notice::add-collection guard OK — the fix pass changed only collections of interface(s) ${ADDED_IFACES} that are not on main, under ${ALLOWED_INDEXES}."
}

case "${1:-}" in
  classify) classify ;;
  enforce)  enforce ;;
  *) note "usage: $0 classify | enforce   (see the header for the environment each reads)"; exit 2 ;;
esac
