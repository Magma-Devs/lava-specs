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
#   - keyed by a CollectionData 4-tuple (the key the router merges on) that the
#     PR's first commit added, and
#   - not on main under that index, and
#   - under an index the first commit targeted, or under an index that imports
#     one of those, transitively. Under such an importer the collection must
#     carry no apis, inheritance_apis, parse_directives, headers or extensions.
# The importers are in because a collection added to an imported spec leaks into
# every importer, carrying the parent's network values. Each importer then needs
# a collection of its own with the same key: a disabled stub, or an override of
# the inherited verifications. PR #145 (REST on BTC) needed both (DOGE's stub,
# BCH's chain-id), in btc.json and in the importers' own files, and nothing more.
# Adding any OTHER key under an existing index would rewrite what the index
# inherits for it (a child's collection absorbs the parent's of the same key,
# smart-router types/spec/expand.go), so it is outside the rule even when its
# interface is the added one: on an addon PR (jsonrpc|POST|debug) the index
# already serves jsonrpc, and a new jsonrpc|POST|trace is not this PR's. So is
# every spec-level field, every collection on main, every other spec and the
# envelope.
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
# Fails closed: a spec file that does not parse, at the first commit or in a
# catalog, exits 2 rather than switching the guard off. jq reads every document
# from a file, never from an argument (the catalog alone is ~65 KB, and Linux
# caps one argument at 128 KB).
#
# Usage:
#   BASE_REF=origin/main HEAD_REF_NAME=<branch> PR_TITLE=<title> \
#     check_add_collection_pr.sh classify
#   BASE=<sha> START=<sha> TARGETS=A ALLOWED_INDEXES=A,B \
#     ADDED_KEYS='[["rest","","GET",""]]' check_add_collection_pr.sh enforce
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

# A collection's CollectionData as the 4-tuple the router merges on.
CK='def ck: .collection_data | [.api_interface, .internal_path, .type, .add_on] | map(. // "");'

# The catalog at <rev>, written to <out> as one JSON object: index -> {file,
# imports, keys}, where keys are the 4-tuples of every collection the index
# declares. A root JSON that does not parse is fatal: skipping it would drop its
# indexes from the rule.
catalog() {
  local rev=$1 out=$2 f
  : > "$WORK/cat.parts"
  while IFS= read -r f; do
    git show "$rev:$f" > "$WORK/cat.one" \
      || { note "::error::cannot read $f at ${rev:0:7}."; exit 2; }
    jq -c --arg f "$f" "$CK"'
      [ .proposal.specs[]? | {key: .index, value: {file: $f, imports: (.imports // []),
                                                  keys: [.api_collections[]? | ck]}} ]
      | from_entries' "$WORK/cat.one" >> "$WORK/cat.parts" 2>/dev/null \
      || { note "::error::$f does not parse at ${rev:0:7}, so the catalog cannot be built."; exit 2; }
  done < <(git ls-tree --name-only "$rev" | { grep -E '^[^/]+\.json$' || true; })
  jq -s -c 'add // {}' "$WORK/cat.parts" > "$out"
}

# Under an importer, a freed collection may be a stub or a verifications-only
# override: nothing that serves or reshapes an API.
CONTENT='def content: [.apis, .inheritance_apis, .parse_directives, .headers, .extensions]
                     | any(. != null and . != []);'

# Drops what the rule allows to change: under an allowed index, every collection
# whose key the first commit added and that is not in the merge-base catalog —
# under an importer, only when it carries no content. What is left must not move.
MASK="$CK $CONTENT"'
  ($allowed | split(",")) as $A | ($targets | split(",")) as $T | $keys[0] as $K
  | .proposal.specs |= ((. // []) | map(
      . as $s
      | if ($A | index($s.index)) then
          .api_collections = [ (.api_collections // [])[] as $c
            | select((($base[0][$s.index].keys // []) | index([$c | ck]))
                     or (($K | index([$c | ck])) | not)
                     or ((($T | index($s.index)) | not) and ($c | content)))
            | $c ]
        else . end))'

# The importer collections the mask kept only because they carry content.
IMPORTER_CONTENT="$CK $CONTENT"'
  ($allowed | split(",")) as $A | ($targets | split(",")) as $T | $keys[0] as $K
  | .proposal.specs[]? | . as $s
  | select(($A | index($s.index)) and (($T | index($s.index)) | not))
  | .api_collections[]? | ck as $k | select(($K | index([$k])) and content)
  | "importer-content|\($s.index)|\($k | join("|"))"'

# What differs between two masked docs, one line per finding.
DELTA='
  def keyof: .collection_data | [.api_interface, .internal_path, .type, .add_on] | join("|");
  def specs: [.proposal.specs[]? | {key: .index, value: .}] | from_entries;
  ($a[0] | specs) as $sa | ($b[0] | specs) as $sb
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
  (if ($a[0] | del(.proposal.specs)) != ($b[0] | del(.proposal.specs)) then "envelope" else empty end)'

# shellcheck disable=SC2153  # TARGETS and ALLOWED_INDEXES are enforce's environment
mask() {  # <file> -> canonical masked JSON on stdout
  jq -S -c --slurpfile base "$WORK/basecat.json" --slurpfile keys "$WORK/keys.json" \
    --arg allowed "$ALLOWED_INDEXES" --arg targets "$TARGETS" "$MASK" "$1"
}

classify() {
  local base_ref="${BASE_REF:-origin/main}" start base first f idx rc tmp="$WORK"
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

  local targets=""
  : > "$tmp/added.parts"
  for f in "${files[@]}"; do
    git show "$first^:$f" > "$tmp/before.json" 2>/dev/null || na "$f is new in the first commit (a new-chain PR)"
    git show "$first:$f" > "$tmp/after.json" 2>/dev/null || na "the first commit deletes $f"
    jq -c -n --slurpfile b "$tmp/before.json" --slurpfile a "$tmp/after.json" "$CK"'
        ($b[0].proposal.specs // [] | map({key: .index, value: [.api_collections[]? | ck]})
         | from_entries) as $known
        | [ $a[0].proposal.specs[]? | select(.index as $i | $known | has($i))
            | . as $s | ([.api_collections[]? | ck] - $known[$s.index]) as $new
            | select($new | length > 0)
            | {index: $s.index, keys: $new} ]' > "$tmp/added.json" 2>/dev/null \
      || { note "::error::$f does not parse on one side of the first commit ${first:0:7} — cannot classify the PR."; exit 2; }
    idx="$(jq -r 'map(.index) | join(",")' "$tmp/added.json")"
    [ -n "$idx" ] || na "$f: the first commit adds no collection to an existing spec"
    rc=0; bash "$CCA" "$tmp/before.json" "$tmp/after.json" "$idx" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) ;;
      1) na "$f: the first commit changes more than it adds (an update, add-testnet or mixed PR)" ;;
      *) note "::error::check_collection_addition.sh could not read $f at the first commit (exit $rc) — cannot classify the PR."; exit 2 ;;
    esac
    targets="${targets:+$targets,}$idx"
    cat "$tmp/added.json" >> "$tmp/added.parts"
  done
  targets="$(tr ',' '\n' <<<"$targets" | sort -u | paste -sd, -)"

  # The exact keys the first commit added, under any target: the only keys the
  # fix pass may free.
  local keys keys_text
  keys="$(jq -s -c 'map(.[].keys[]) | unique' "$tmp/added.parts")"
  keys_text="$(jq -r 'map(join("|")) | join(", ")' <<<"$keys")"

  # Allowed = the targets and everything that imports them, transitively, read
  # from the pre-agent head so the agent cannot widen it by adding an import.
  local allowed importers
  catalog "$start" "$tmp/startcat.json"
  allowed="$(jq -r --arg t "$targets" '
      [ to_entries[] | {child: .key, parents: .value.imports} ] as $edges
      | def grow($set):
          ([ $edges[] | select(any(.parents[]; . as $p | $set | index($p))) | .child ] + $set | unique) as $next
          | if ($next | length) == ($set | length) then $set else grow($next) end;
        grow($t | split(",") | unique) | join(",")' "$tmp/startcat.json")"
  importers="$(comm -13 <(tr ',' '\n' <<<"$targets" | sort) <(tr ',' '\n' <<<"$allowed" | sort) | paste -sd, -)"

  local rule="- ADD-COLLECTION PR (a guard enforces this): the Phase-10 fix pass may change ONLY the api_collections this PR added, keyed (api_interface|internal_path|type|add_on) ${keys_text}, on ${targets}"
  if [ -n "$importers" ]; then
    rule+=", plus, on the specs that import them (${importers}), a collection with one of those keys only where the import leaks the new one with the wrong values: a disabled stub, or an override of the inherited verifications, with no apis, inheritance_apis, parse_directives, headers or extensions, in that spec's own file"
  fi
  rule+=". Do not change any spec-level field or any collection that is on main, do not add a collection with any other key (even of the same api_interface), and do not touch any other spec: report such findings instead of fixing them. The guard refuses the whole commit otherwise."

  note "::notice::add-collection guard ENFORCING — ${keys_text} on ${targets}${importers:+, importers ${importers}}, first commit ${first:0:7}"
  out ENFORCE true
  out BASE "$base"
  out START "$start"
  out FIRST "$first"
  out TARGETS "$targets"
  out ALLOWED_INDEXES "$allowed"
  out ADDED_KEYS "$keys"
  out PROMPT_RULE "$rule"
}

enforce() {
  : "${BASE:?BASE is required}" "${START:?START is required}" "${TARGETS:?TARGETS is required}"
  : "${ALLOWED_INDEXES:?ALLOWED_INDEXES is required}" "${ADDED_KEYS:?ADDED_KEYS is required}"
  git cat-file -e "$START^{commit}" 2>/dev/null || { note "::error::START $START is not a commit here."; exit 2; }
  printf '%s' "$ADDED_KEYS" > "$WORK/keys.json"
  jq -e 'type == "array" and length > 0 and all(type == "array" and length == 4)' "$WORK/keys.json" >/dev/null 2>&1 \
    || { note "::error::ADDED_KEYS is not a list of CollectionData 4-tuples: $ADDED_KEYS"; exit 2; }
  catalog "$BASE" "$WORK/basecat.json"

  local tmp="$WORK" f refused=0 keys_text
  keys_text="$(jq -r 'map(join("|")) | join(", ")' "$WORK/keys.json")"

  # Drift the branch already carries is not this run's, and never blocks it. It
  # is said, once, so nobody reads a pass as "the branch is clean".
  local drift=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! git show "$BASE:$f" > "$tmp/x.json" 2>/dev/null; then drift+=("$f (new)"); continue; fi
    git show "$START:$f" > "$tmp/y.json" 2>/dev/null || { drift+=("$f (deleted)"); continue; }
    mask "$tmp/x.json" > "$tmp/xm.json" 2>/dev/null || { drift+=("$f"); continue; }
    mask "$tmp/y.json" > "$tmp/ym.json" 2>/dev/null || { drift+=("$f"); continue; }
    cmp -s "$tmp/xm.json" "$tmp/ym.json" || drift+=("$f")
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
    mask "$tmp/start.json" > "$tmp/a.json"
    mask "$f" > "$tmp/b.json"
    if ! cmp -s "$tmp/a.json" "$tmp/b.json"; then
      refused=1
      note "::error::the fix pass changed '$f' outside what this add-collection PR may change:"
      jq -r -n --slurpfile a "$tmp/a.json" --slurpfile b "$tmp/b.json" "$DELTA" | sed 's/^/    /' >&2
      jq -r --slurpfile keys "$WORK/keys.json" --arg allowed "$ALLOWED_INDEXES" --arg targets "$TARGETS" \
        "$IMPORTER_CONTENT" "$f" | sed 's/^/    /; s/$/  (an importer may get only a stub or a verifications-only override)/' >&2
    fi
  done

  if [ "$refused" -ne 0 ]; then
    local importers
    importers="$(comm -13 <(tr ',' '\n' <<<"$TARGETS" | sort) <(tr ',' '\n' <<<"$ALLOWED_INDEXES" | sort) | paste -sd, -)"
    note "Allowed: collections keyed ${keys_text} that are not on main, under ${TARGETS}${importers:+, and content-free ones (a stub or a verifications-only override) under ${importers}}. Refusing to commit."
    note "A change the PR really needs goes in as its own commit, by hand. A committed change is not judged again."
    exit 1
  fi
  note "::notice::add-collection guard OK — the fix pass changed only collections keyed ${keys_text} that are not on main, under ${ALLOWED_INDEXES}."
}

case "${1:-}" in
  classify) classify ;;
  enforce)  enforce ;;
  *) note "usage: $0 classify | enforce   (see the header for the environment each reads)"; exit 2 ;;
esac
