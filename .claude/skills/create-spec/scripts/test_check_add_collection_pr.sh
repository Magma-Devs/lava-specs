#!/usr/bin/env bash
# check_add_collection_pr.sh, both halves, against throwaway git repos: a bare
# origin and a clone whose main holds a small catalog, then a PR branch whose
# first commit adds collections, then an "agent" that edits the working tree.
#
#   hedera.json  HEDERA, HEDERAT (import ETH1)   no importers
#   btc.json     BTC; BTCT, BTCS import BTC      importers in the same file
#   bch.json     BCH imports BTC; BCHT imports BCH   importers, transitively
#   doge.json    DOGE imports BTC
#   other.json   OTHER                           unrelated
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_add_collection_pr.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "$1: OK"; }

spec() { # <index> [imports,csv] — one spec with one jsonrpc collection
  jq -n -c --arg i "$1" --arg imp "${2:-}" '{index: $i, name: $i, enabled: true,
    imports: (if $imp == "" then [] else ($imp | split(",")) end), average_block_time: 2000,
    api_collections: [{enabled: true,
      collection_data: {api_interface: "jsonrpc", internal_path: "", type: "POST", add_on: ""},
      apis: [{name: "eth_blockNumber", enabled: true}], headers: [], inheritance_apis: [],
      parse_directives: [], verifications: [{name: "chain-id", values: [{expected_value: ("0x" + $i)}]}]}]}'
}
coll() { # <iface> <type> [enabled] [chain-id] [add_on]
  jq -n -c --arg i "$1" --arg t "$2" --argjson e "${3:-true}" --arg v "${4:-}" --arg o "${5:-}" '{enabled: $e,
    collection_data: {api_interface: $i, internal_path: "", type: $t, add_on: $o},
    apis: [], headers: [], inheritance_apis: [], parse_directives: [],
    verifications: (if $v == "" then [] else [{name: "chain-id", values: [{expected_value: $v}]}] end)}'
}
jqi() { jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
addc() { jqi "$1" ".proposal.specs |= map(if .index == \"$2\" then .api_collections += [$3] else . end)"; }
catalog_file() { local f=$1; shift; printf '%s\n' "$@" | jq -s '{proposal: {specs: .}}' > "$f"; }

repo() { # -> a work dir on branch pr, main pushed to a bare origin
  local d
  d="$(mktemp -d "$T/r.XXXXXX")"  # not a counter: repo() runs in $(...), a subshell
  git init -q --bare "$d/origin.git"
  git init -q -b main "$d/work"
  (
    cd "$d/work"
    git config user.name t; git config user.email t@t
    catalog_file ethereum.json "$(spec ETH1)"
    catalog_file hedera.json "$(spec HEDERA ETH1)" "$(spec HEDERAT ETH1)"
    catalog_file btc.json "$(spec BTC)" "$(spec BTCT BTC)" "$(spec BTCS BTC)"
    catalog_file bch.json "$(spec BCH BTC)" "$(spec BCHT BCH)"
    catalog_file doge.json "$(spec DOGE BTC)"
    catalog_file other.json "$(spec OTHER)"
    git add -A && git commit -qm catalog
    git remote add origin "$d/origin.git" && git push -q origin main && git fetch -q origin
    git switch -q -c pr
  )
  echo "$d/work"
}

classify() { # <dir> [VAR=value...] -> CRC, COUT, CERR
  local d=$1; shift
  set +e
  COUT="$(cd "$d" && env BASE_REF=origin/main "$@" bash "$SCRIPT" classify 2>"$T/err")"
  CRC=$?
  set -e
  CERR="$(cat "$T/err")"
}
get() { sed -n "s/^$1=//p" <<<"$COUT"; }
enforce() { # <dir> -> ERC, EOUT (the classification in COUT is the one enforced)
  set +e
  EOUT="$(cd "$1" && env BASE="$(get BASE)" START="$(get START)" TARGETS="$(get TARGETS)" \
          ALLOWED_INDEXES="$(get ALLOWED_INDEXES)" ADDED_KEYS="$(get ADDED_KEYS)" bash "$SCRIPT" enforce 2>&1)"
  ERC=$?
  set -e
}
want_enforcing() { [ "$CRC" -eq 0 ] && [ "$(get ENFORCE)" = true ] || fail "$1: want ENFORCE=true (rc=$CRC): $CERR"; }
want_na() {
  [ "$CRC" -eq 0 ] && [ "$(get ENFORCE)" = false ] || fail "$1: want N/A (rc=$CRC): $COUT $CERR"
  grep -q -- "$2" <<<"$CERR" || fail "$1: want N/A reason '$2': $CERR"
}
want_pass() { [ "$ERC" -eq 0 ] || fail "$1: want pass (rc=$ERC): $EOUT"; }
want_refused() {
  [ "$ERC" -eq 1 ] || fail "$1: want refused (rc=$ERC): $EOUT"
  grep -q -- "$2" <<<"$EOUT" || fail "$1: want '$2' in: $EOUT"
}

hedera_pr() { # the first commit adds rest to HEDERA and HEDERAT (PR #162's shape)
  local w; w="$(repo)"
  ( cd "$w" && addc hedera.json HEDERA "$(coll rest GET true genesis-hash)" \
      && addc hedera.json HEDERAT "$(coll rest GET)" && git commit -qam "add rest" )
  echo "$w"
}
btc_pr() { # the first commit adds rest to BTC only (PR #145's shape)
  local w; w="$(repo)"
  ( cd "$w" && addc btc.json BTC "$(coll rest GET true bitcoin)" && git commit -qam "add rest to btc" )
  echo "$w"
}

# --- classify: what kind of PR this is ------------------------------------------

w="$(hedera_pr)"; classify "$w"
want_enforcing "hedera classify"
[ "$(get TARGETS)" = "HEDERA,HEDERAT" ] || fail "hedera targets: $(get TARGETS)"
[ "$(get ALLOWED_INDEXES)" = "HEDERA,HEDERAT" ] || fail "hedera allowed: $(get ALLOWED_INDEXES)"
[ "$(get ADDED_KEYS)" = '[["rest","","GET",""]]' ] || fail "hedera keys: $(get ADDED_KEYS)"
grep -q "keyed (api_interface|internal_path|type|add_on) rest||GET|, on HEDERA,HEDERAT" <<<"$(get PROMPT_RULE)" \
  || fail "hedera prompt rule: $(get PROMPT_RULE)"
grep -q "ALLOWED_FILES" <<<"$COUT" && fail "ALLOWED_FILES is no longer an output"
ok "hedera classify"

w="$(btc_pr)"; classify "$w"
want_enforcing "btc classify"
[ "$(get ALLOWED_INDEXES)" = "BCH,BCHT,BTC,BTCS,BTCT,DOGE" ] || fail "btc allowed (transitive importers): $(get ALLOWED_INDEXES)"
grep -q "import them (BCH,BCHT,BTCS,BTCT,DOGE)" <<<"$(get PROMPT_RULE)" || fail "btc prompt rule: $(get PROMPT_RULE)"
grep -q "with no apis, inheritance_apis" <<<"$(get PROMPT_RULE)" || fail "btc prompt rule (importer shape): $(get PROMPT_RULE)"
ok "btc classify (importers, transitively)"

w="$(repo)"; ( cd "$w" && catalog_file newchain.json "$(spec NEW)" && git add -A && git commit -qm new ); classify "$w"
want_na "new chain" "new-chain PR"; ok "new chain: N/A"

w="$(repo)"; ( cd "$w" && jqi hedera.json ".proposal.specs += [$(spec HEDERAT2 HEDERA)]" && git commit -qam testnet ); classify "$w"
want_na "add-testnet" "adds no collection"; ok "add-testnet: N/A"

w="$(hedera_pr)"; classify "$w" HEAD_REF_NAME=hedera-spec-update-28-09-2026
want_na "update branch" "update-mode"; ok "update-mode branch: N/A"
classify "$w" PR_TITLE="feat(spec): update Hedera spec with missing methods"
want_na "update title" "update-mode"; ok "update-mode title: N/A"

w="$(repo)"; ( cd "$w" && addc hedera.json HEDERA "$(coll rest GET)" \
  && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .average_block_time) = 1' && git commit -qam mixed ); classify "$w"
want_na "mixed first commit" "changes more than it adds"; ok "mixed first commit: N/A"

w="$(repo)"; classify "$w"
want_na "no commits" "no commits past main"; ok "no commits past main: N/A"

w="$(repo)"; ( cd "$w" && echo x > notes.md && git add -A && git commit -qm docs ); classify "$w"
want_na "no spec in first commit" "changes no root spec file"; ok "first commit touches no spec: N/A"

# Fails closed: unparseable input exits 2, it does not switch the guard off.
w="$(repo)"; ( cd "$w" && printf '{"proposal": {' > hedera.json && git commit -qam corrupt ); classify "$w"
[ "$CRC" -eq 2 ] || fail "corrupt first commit: want exit 2 (rc=$CRC): $COUT $CERR"
grep -q "does not parse" <<<"$CERR" || fail "corrupt first commit: $CERR"
ok "a first commit that does not parse: exit 2, not N/A"

w="$(hedera_pr)"; ( cd "$w" && echo '{' > broken.json && git add broken.json && git commit -qm "a broken root json" ); classify "$w"
[ "$CRC" -eq 2 ] || fail "corrupt catalog file: want exit 2 (rc=$CRC): $COUT $CERR"
grep -q "broken.json does not parse" <<<"$CERR" || fail "corrupt catalog file: $CERR"
ok "a root JSON that does not parse in the catalog: exit 2, not dropped"

printf '#!/usr/bin/env bash\nexit 2\n' > "$T/cca2.sh"
w="$(hedera_pr)"; classify "$w" CCA="$T/cca2.sh"
[ "$CRC" -eq 2 ] || fail "check_collection_addition.sh exit 2: want exit 2 (rc=$CRC): $COUT $CERR"
ok "check_collection_addition.sh cannot read its input: exit 2, not N/A"

# --- enforce: what the fix pass may change --------------------------------------

w="$(hedera_pr)"; classify "$w"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections[1].apis) += [{name: "/api/v1/blocks"}]' )
enforce "$w"; want_pass "fix inside the added rest"; ok "fix inside the added collection: pass"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERAT") | .api_collections[0].verifications[0].values[0].expected_value) = "0x1"' )
enforce "$w"; want_refused "jsonrpc edit" "collection-changed|HEDERAT|jsonrpc||POST|"; ok "jsonrpc edit: refused"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .average_block_time) = 2340' )
enforce "$w"; want_refused "spec field" "spec-fields|HEDERA"; ok "spec-level field: refused"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && addc hedera.json HEDERAT "$(coll jsonrpc POST true "" debug)" )
enforce "$w"; want_refused "another interface" "collection-added|HEDERAT|jsonrpc||POST|debug"; ok "new collection of another interface: refused"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && addc hedera.json HEDERA "$(coll rest POST)" )
enforce "$w"; want_refused "another key, same interface" "collection-added|HEDERA|rest||POST|"
ok "a new key of the added interface that the PR did not add: refused"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && addc other.json OTHER "$(coll rest GET)" )
enforce "$w"; want_refused "untargeted index" "other.json"; ok "collection under an untargeted index: refused"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && echo '{}' > stray.json )
enforce "$w"; want_pass "untracked only"; grep -q "nothing to commit" <<<"$EOUT" || fail "untracked only: $EOUT"
ok "untracked root JSON with nothing tracked changed: pass (the commit step pushes nothing)"

( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections[1].enabled) = false' )
enforce "$w"; want_refused "untracked with a tracked change" "created 'stray.json'"; ok "untracked root JSON beside a real change: refused"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && jqi other.json '.proposal.specs[0].name = "x"' && git commit -qam "agent commits a stray edit" \
    && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections[1].enabled) = false' )
enforce "$w"; want_refused "local commit" "changed 'other.json'"; ok "a stray edit the agent committed locally: refused"

w="$(hedera_pr)"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERAT") | .api_collections[0].apis) += [{name: "eth_x"}]' \
    && git commit -qam "maintainer: a deliberate jsonrpc change" )
classify "$w"; want_enforcing "maintainer commit keeps the classification"
enforce "$w"; want_pass "nothing to commit, drift committed"
grep -q "::warning::the branch already carries committed changes" <<<"$EOUT" || fail "drift warning: $EOUT"
ok "committed drift, nothing to commit: pass, with a warning"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections[1].apis) += [{name: "/x"}]' )
enforce "$w"; want_pass "committed drift, clean fix"; ok "committed drift, then a clean fix: pass"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections) |= .[:1]' )
enforce "$w"; want_pass "dropping an added collection"; ok "the fix drops one of the added collections: pass"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && rm hedera.json )
enforce "$w"; want_refused "deleted target" "deleted 'hedera.json'"; ok "deleted target: refused"

w="$(hedera_pr)"; classify "$w"
( cd "$w" && printf '{"proposal": {' > hedera.json )
enforce "$w"; want_refused "corrupt target" "does not parse"; ok "corrupt target: refused"

w="$(hedera_pr)"
( cd "$w" && git switch -q main && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .average_block_time) = 1999' \
    && git commit -qam "main moves" && git push -q origin main && git fetch -q origin && git switch -q pr )
classify "$w"; want_enforcing "main moved"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections[1].apis) += [{name: "/y"}]' )
enforce "$w"; want_pass "main moved, clean fix"; ok "main changed the same file after the branch point: pass"

# An index that already serves the interface on main: the PR adds a rest archive
# addon beside OTHER's rest base collection. The base collection is on main, so it
# is out of bounds although its interface is the added one.
w="$(repo)"
( cd "$w" && git switch -q main && addc other.json OTHER "$(coll rest GET)" && git commit -qam "rest on main" \
    && git push -q origin main && git fetch -q origin && git switch -q -C pr main \
    && addc other.json OTHER "$(coll rest GET true "" archive)" && git commit -qam "add a rest archive addon" )
classify "$w"; want_enforcing "addon beside an existing interface"
[ "$(get ADDED_KEYS)" = '[["rest","","GET","archive"]]' ] || fail "addon keys: $(get ADDED_KEYS)"
( cd "$w" && jqi other.json '(.proposal.specs[0].api_collections[] | select(.collection_data.add_on == "archive") | .apis) += [{name: "/a"}]' )
enforce "$w"; want_pass "fix inside the added addon"
( cd "$w" && jqi other.json '(.proposal.specs[0].api_collections[] | select(.collection_data.api_interface == "rest" and .collection_data.add_on == "") | .apis) += [{name: "/b"}]' )
enforce "$w"; want_refused "on-main collection of the added interface" "collection-changed|OTHER|rest||GET|"
ok "an on-main collection of the added interface: refused; the added addon beside it: pass"

# The addon PR's interface is already served, so keying on the interface would
# free every new key of it. Only the added key is freed.
w="$(repo)"
( cd "$w" && addc other.json OTHER "$(coll jsonrpc POST true "" debug)" && git commit -qam "add a jsonrpc debug addon" )
classify "$w"; want_enforcing "jsonrpc addon"
[ "$(get ADDED_KEYS)" = '[["jsonrpc","","POST","debug"]]' ] || fail "jsonrpc addon keys: $(get ADDED_KEYS)"
( cd "$w" && jqi other.json '(.proposal.specs[0].api_collections[] | select(.collection_data.add_on == "debug") | .apis) += [{name: "debug_x"}]' )
enforce "$w"; want_pass "fix inside the added jsonrpc addon"
( cd "$w" && addc other.json OTHER "$(coll jsonrpc POST true "" trace)" )
enforce "$w"; want_refused "a second jsonrpc addon" "collection-added|OTHER|jsonrpc||POST|trace"
ok "addon PR: the added addon may change, a new addon of the same interface is refused"

# --- enforce on an imported spec (PR #145's shape) -------------------------------

w="$(btc_pr)"; classify "$w"
( cd "$w" && addc doge.json DOGE "$(coll rest GET false)" && addc bch.json BCH "$(coll rest GET true bitcoincash)" \
    && addc btc.json BTCS "$(coll rest GET false)" && addc bch.json BCHT "$(coll rest GET false)" )
enforce "$w"; want_pass "importer stubs and overrides"
ok "importers get a disabled stub or an overriding collection, in their own files: pass"

w="$(btc_pr)"; classify "$w"
( cd "$w" && jqi bch.json '(.proposal.specs[] | select(.index=="BCH") | .api_collections[0].apis) += [{name: "x"}]' )
enforce "$w"; want_refused "importer's jsonrpc" "collection-changed|BCH|jsonrpc||POST|"; ok "an importer's existing collection: refused"

w="$(btc_pr)"; classify "$w"
( cd "$w" && addc doge.json DOGE "$(coll rest GET true dogecoin | jq -c '.apis = [{name: "/block", enabled: true}]')" )
enforce "$w"; want_refused "importer with apis" "importer-content|DOGE|rest||GET|"
grep -q "collection-added|DOGE|rest||GET|" <<<"$EOUT" || fail "importer with apis delta: $EOUT"
ok "an importer collection that serves apis: refused"

w="$(btc_pr)"; classify "$w"
( cd "$w" && addc doge.json DOGE "$(coll rest GET false | jq -c '.headers = [{name: "x-api-key", kind: "pass_send"}]')" )
enforce "$w"; want_refused "importer with headers" "importer-content|DOGE|rest||GET|"
ok "an importer collection that declares headers: refused"

w="$(btc_pr)"; classify "$w"
( cd "$w" && addc doge.json DOGE "$(coll rest POST false)" )
enforce "$w"; want_refused "importer, key not added" "collection-added|DOGE|rest||POST|"
ok "an importer stub for a key the PR did not add: refused"

w="$(btc_pr)"
( cd "$w" && addc doge.json DOGE "$(coll rest GET false)" && git commit -qam "stub doge" )
classify "$w"; want_enforcing "a later commit in another file"
( cd "$w" && jqi btc.json '(.proposal.specs[] | select(.index=="BTC") | .api_collections[1].apis) += [{name: "/tx"}]' )
enforce "$w"; want_pass "later importer commit, clean fix"
ok "a later commit in an importer's file does not switch the guard off"

# Large documents go to jq as files: a refusal on a spec past Linux's 128 KB
# per-argument limit must still print its findings, not E2BIG.
w="$(repo)"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections[0].apis) +=
      [range(4000) | {name: ("eth_padding_method_\(.)"), enabled: true, compute_units: 10}]' \
    && git commit -qam "big jsonrpc" && git push -q origin HEAD:main && git fetch -q origin \
    && addc hedera.json HEDERA "$(coll rest GET)" && git commit -qam "add rest" )
[ "$(wc -c < "$w/hedera.json")" -gt 131072 ] || fail "large doc fixture is too small"
classify "$w"; want_enforcing "large doc"
( cd "$w" && jqi hedera.json '(.proposal.specs[] | select(.index=="HEDERA") | .api_collections[0].apis[0].enabled) = false' )
enforce "$w"; want_refused "large doc" "collection-changed|HEDERA|jsonrpc||POST|"
ok "a refusal on a spec larger than one argument may be: findings printed"

echo "ALL OK"
