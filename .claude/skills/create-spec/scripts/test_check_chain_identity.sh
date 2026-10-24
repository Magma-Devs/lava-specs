#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_chain_identity.sh"
JQPROG="$DIR/chain_identity.jq"
FIX="$DIR/fixtures/chain_identity"
EMPTY_BASELINE="$(mktemp)"
BROKEN_DIR="$(mktemp -d)"
trap 'rm -f "$EMPTY_BASELINE"; rm -rf "${BROKEN_DIR:?}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Rows under "=== NEW CHAIN-IDENTITY FINDINGS ===", key only (the part before
# "<- passes for:"). The section is followed by prose, so match the row SHAPE.
new_rows() {
  echo "$1" | awk '/^=== NEW CHAIN-IDENTITY/{f=1;next} /^=== /{f=0} f' \
    | grep -E '^(UNSEPARATED|UNIDENTIFIED) ' | sed 's/   <- passes for:.*//' || true
}
passes_for() {  # passes_for "<output>" "<KIND INDEX iface path>" -> the "passes for" list
  echo "$1" | grep -F "$2   <- passes for: " | sed 's/.*<- passes for: //' || true
}

# --- expansion: chain_identity.jq must match the router -----------------------
# expand.golden.tsv is the ROUTER's output, not this guard's: smart-router
# v1.5.8's keeper.ExpandSpecWithDependencies over this directory, with a fresh
# catalogue load per index, printing every effective verification value of
# every enabled collection. Regenerate it the same way whenever a fixture
# changes — never from chain_identity.jq, or the test proves nothing.
#
# What it pins: values-only overrides borrowing the parent's request
# (FXBASET, FXINH), a grandchild with no collections inheriting wholesale
# (FXFORKT), inheritance_apis through a disabled base collection (FXINH), the
# ORDER dependence of inheritance_apis (FXORD /a expands from the base before
# the base inherits FXPAR, so /a has no pextra), and two parents merged into
# one collection (FXMULTI).
GOT="$(jq -n -r --arg mode expand -f "$JQPROG" "$FIX"/*.json | sort)"
WANT="$(sort "$FIX/expand.golden.tsv")"
[ "$GOT" = "$WANT" ] || fail "expansion differs from the router's golden:
$(diff <(echo "$WANT") <(echo "$GOT") | head -20)"
echo "expansion: OK ($(echo "$WANT" | wc -l | tr -d ' ') verification values match the router)"

# --- no baseline: every finding is new ---------------------------------------
set +e; OUT=$("$SCRIPT" --specs-dir "$FIX" --baseline "$EMPTY_BASELINE"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "no baseline: exit=$RC, want 1"
WANT_ROWS="UNIDENTIFIED FXFETCH jsonrpc -
UNIDENTIFIED FXNONE jsonrpc -
UNIDENTIFIED FXWARN jsonrpc -
UNSEPARATED FXBASE jsonrpc -
UNSEPARATED FXFORK jsonrpc -
UNSEPARATED FXFORKT jsonrpc -
UNSEPARATED FXMP1 rest -
UNSEPARATED FXMP2 rest -"
GOT_ROWS="$(new_rows "$OUT" | sort)"
[ "$GOT_ROWS" = "$WANT_ROWS" ] || fail "no baseline: findings differ:
--- want
$WANT_ROWS
--- got
$GOT_ROWS"
echo "no baseline: OK (8 findings, exit 1)"

# A fork that keeps its parent's answer, and its grandchild, are each other's
# twins — the BTC/BCH/DOGE shape. The disabled spec FXOFF and FXDIS's disabled
# collection carry the same answers and must not be counted.
[ "$(passes_for "$OUT" "UNSEPARATED FXBASE jsonrpc -")" = "FXFORK FXFORKT" ] \
  || fail "FXBASE: want 'passes for: FXFORK FXFORKT', got '$(passes_for "$OUT" "UNSEPARATED FXBASE jsonrpc -")'"
echo "$OUT" | grep -q 'FXOFF' && fail "a disabled spec (FXOFF) was reported or counted"
echo "$OUT" | grep -q 'FXDIS' && fail "a disabled collection (FXDIS trace) was counted"
echo "inheritance: OK (fork twins flagged, disabled spec and collection ignored)"

# Not findings, each for a reason the guard must keep honouring:
#   FXBASET          overrides the inherited value with its own
#   FXREST1/FXREST2  the same value `1`, but to different requests
#   FXTWO/FXTWOT     the same coin; the second check tells the networks apart
#   FXSUB/FXSUBT     the add-on answer is shared; the base check separates them
#   FXINH            inherits the request through a disabled base, own value
for idx in FXBASET FXREST1 FXREST2 FXTWO FXTWOT FXSUB FXSUBT FXINH FXPAR FXORD FXMULTI; do
  new_rows "$OUT" | grep -q " $idx " && fail "$idx was reported but is separated"
done
echo "separated shapes: OK (same value / second check / base check / borrowed request)"

# Accept-anything, Warning-only, and GET_BLOCK_BY_NUM (a height to fetch, no
# compare) all leave an endpoint unidentified.
for idx in FXNONE FXWARN FXFETCH; do
  new_rows "$OUT" | grep -qx "UNIDENTIFIED $idx jsonrpc -" || fail "$idx should be UNIDENTIFIED"
done
echo "unidentified: OK ('*', Warning, GET_BLOCK_BY_NUM)"

# --- full baseline: clean ----------------------------------------------------
OUT=$("$SCRIPT" --specs-dir "$FIX" --baseline "$FIX/baseline_all.txt")
[ -z "$(new_rows "$OUT")" ] || fail "full baseline: unexpected new rows: $(new_rows "$OUT")"
echo "$OUT" | grep -q '^=== KNOWN' || fail "full baseline: missing KNOWN section"
echo "$OUT" | grep -q '^OK: ' || fail "full baseline: missing OK line"
echo "full baseline: OK (exit 0, 8 known)"

# --- partial baseline: fails on exactly the rows it lacks --------------------
set +e; OUT=$("$SCRIPT" --specs-dir "$FIX" --baseline "$FIX/baseline_partial.txt"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "partial baseline: exit=$RC, want 1"
[ "$(new_rows "$OUT" | sort)" = "UNSEPARATED FXMP1 rest -
UNSEPARATED FXMP2 rest -" ] || fail "partial baseline: want FXMP1 and FXMP2 new, got: $(new_rows "$OUT")"
echo "partial baseline: OK (2 new, exit 1)"

# --- a stale row fails: the ledger cleans itself ------------------------------
set +e; OUT=$("$SCRIPT" --specs-dir "$FIX" --baseline "$FIX/baseline_stale.txt"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "stale: exit=$RC, want 1"
echo "$OUT" | grep -q '^=== STALE BASELINE ROWS' || fail "stale: missing STALE section"
echo "$OUT" | grep -qx 'UNSEPARATED FXTWO rest -' || fail "stale: row not named"
echo "stale: OK (untagged stale row fails)"

# --- a stale TEMPORARY row reports and passes --------------------------------
OUT=$("$SCRIPT" --specs-dir "$FIX" --baseline "$FIX/baseline_stale_temp.txt") \
  || fail "stale TEMPORARY: exited non-zero"
echo "$OUT" | grep -q '^=== STALE, TEMPORARY' || fail "stale TEMPORARY: missing section"
echo "$OUT" | grep -q '^=== STALE BASELINE ROWS' && fail "stale TEMPORARY: reported as a failing stale row"
echo "stale TEMPORARY: OK (reported, exit 0)"

# --- fail closed on an unreadable catalogue -----------------------------------
cp "$FIX"/*.json "$BROKEN_DIR"/
printf '{"proposal": {"specs": [' > "$BROKEN_DIR/zz_broken.json"
set +e; OUT=$("$SCRIPT" --specs-dir "$BROKEN_DIR" --baseline "$FIX/baseline_all.txt" 2>&1); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "broken json: exit=$RC, want 1 (fail closed)"
echo "$OUT" | grep -q 'could not expand the catalogue' || fail "broken json: missing fail-closed message"
echo "broken json: OK (fails closed)"

# --- usage --------------------------------------------------------------------
set +e; "$SCRIPT" --no-such-flag >/dev/null 2>&1; RC=$?; set -e
[ "$RC" -eq 2 ] || fail "usage: exit=$RC, want 2"
echo "usage: OK"

echo "ALL OK"
