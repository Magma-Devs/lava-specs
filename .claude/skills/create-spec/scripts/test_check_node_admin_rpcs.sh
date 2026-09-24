#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_node_admin_rpcs.sh"
FIX="$DIR/fixtures"
EMPTY_BASELINE="$(mktemp)"
trap 'rm -f "$EMPTY_BASELINE"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Findings under "=== NEW NODE-ADMIN EXPOSURE ===". The section is followed by
# prose, so match the row SHAPE (INDEX/interface/method) rather than trying to
# find where the prose starts.
new_rows() {
  echo "$1" | awk '/^=== NEW NODE-ADMIN/{f=1;next} /^=== /{f=0} f' \
    | grep -E '^[A-Za-z0-9_]+/[a-z]+/[A-Za-z0-9_]+$' || true
}

# --- clean spec: disabled controls, a legitimate write, an add-on-gated one ---
OUT=$("$SCRIPT" "$FIX/node_admin_good.json" --baseline "$EMPTY_BASELINE")
N=$(new_rows "$OUT" | wc -l | tr -d ' ')
[ "$N" -eq 0 ] || fail "good: expected 0 new findings, got $N:
$(new_rows "$OUT")"
echo "good: OK (no findings)"

# A disabled control must not be flagged — otherwise the guard rejects the very
# PR that fixes a spec by disabling them (MAG-3644's own fix shape).
echo "$OUT" | grep -qE '^=== NEW NODE-ADMIN' || fail "good: missing NEW section header"
new_rows "$OUT" | grep -q 'parkblock' && fail "good: flagged a DISABLED parkblock"
echo "good: disabled controls not flagged: OK"

# submitblock is deliberately out of the set — it changes chain state, not the
# node's view of it, and its typing belongs to the method-schema gate.
new_rows "$OUT" | grep -q 'submitblock' && fail "good: flagged submitblock (out of scope by design)"
echo "good: submitblock out of scope: OK"

# An add-on is an opt-in boundary; report it, do not fail on it.
echo "$OUT" | grep -q 'debug_setHead' || fail "good: add-on-gated method missing from INFO"
echo "$OUT" | grep -qE 'behind add_on "debug"' || fail "good: add-on method not reported as gated"
echo "good: add-on-gated reported as INFO: OK"

# --- bad spec, no baseline: every enabled base-collection control is new ---
set +e; OUT=$("$SCRIPT" "$FIX/node_admin_bad.json" --baseline "$EMPTY_BASELINE"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "bad: exit=$RC, want 1"
N=$(new_rows "$OUT" | wc -l | tr -d ' ')
[ "$N" -eq 4 ] || fail "bad: expected 4 new findings, got $N:
$(new_rows "$OUT")"
for m in finalizeblock parkblock setban personal_unlockAccount; do
  new_rows "$OUT" | grep -q "$m" || fail "bad: did not flag $m"
done
echo "bad: OK (4 findings, exit 1)"

# `personal_` is matched by prefix, so a namespace member the list never
# enumerated is still caught.
new_rows "$OUT" | grep -q 'personal_unlockAccount' || fail "bad: personal_ prefix match broken"
echo "bad: personal_ prefix match: OK"

# --- baseline covers 2 of 4: still fails, and only on the uncovered 2 ---
set +e
OUT=$("$SCRIPT" "$FIX/node_admin_bad.json" --baseline "$FIX/node_admin_baseline_test.txt")
RC=$?
set -e
[ "$RC" -eq 1 ] || fail "baselined: exit=$RC, want 1 (2 findings are still unbaselined)"
N=$(new_rows "$OUT" | wc -l | tr -d ' ')
[ "$N" -eq 2 ] || fail "baselined: expected 2 new findings, got $N:
$(new_rows "$OUT")"
new_rows "$OUT" | grep -q 'finalizeblock' && fail "baselined: finalizeblock should be KNOWN, not NEW"
new_rows "$OUT" | grep -q 'setban' || fail "baselined: setban should still be NEW"
echo "$OUT" | grep -q '=== KNOWN' || fail "baselined: missing KNOWN section"
echo "baselined: OK (2 known, 2 new, exit 1)"

# --- a stale baseline row fails: the ledger cleans itself ---
# node_admin_good.json has parkblock DISABLED, so a baseline row naming it
# describes an exposure that no longer exists. Left in place it would silently
# re-permit the method if the fix were reverted.
set +e; OUT=$("$SCRIPT" "$FIX/node_admin_good.json" --baseline "$FIX/node_admin_baseline_stale.txt"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "stale: exit=$RC, want 1"
echo "$OUT" | grep -q '=== STALE BASELINE ROWS' || fail "stale: missing STALE section"
echo "$OUT" | grep -q 'node_admin_good.json GOODCHAIN jsonrpc parkblock' || fail "stale: row not named"
echo "stale: OK (untagged stale row fails)"

# --- ...except a TEMPORARY row, which is expected to go stale ---
# Reported loudly, but does not fail: the merge that makes it stale is usually
# someone else's and should not turn their CI red.
set +e; OUT=$("$SCRIPT" "$FIX/node_admin_good.json" --baseline "$FIX/node_admin_baseline_stale_temp.txt"); RC=$?; set -e
[ "$RC" -eq 0 ] || fail "stale-temp: exit=$RC, want 0"
echo "$OUT" | grep -q '=== STALE, TEMPORARY' || fail "stale-temp: missing STALE/TEMPORARY section"
echo "$OUT" | grep -q '=== STALE BASELINE ROWS' && fail "stale-temp: must not report as a hard stale row"
echo "stale-temp: OK (reported, does not fail)"

# --- the real baseline must make the shipped catalogue clean ---
# If this fails, the guard cannot be wired as a hard gate without breaking
# unrelated PRs — which is the whole reason the baseline exists.
REPO_ROOT="$(cd "$DIR/../../../.." && pwd)"
if [ -d "$REPO_ROOT" ] && ls "$REPO_ROOT"/*.json >/dev/null 2>&1; then
  dirty=0
  for spec in "$REPO_ROOT"/*.json; do
    if ! "$SCRIPT" "$spec" >/dev/null 2>&1; then
      echo "  catalogue regression: $(basename "$spec")" >&2
      dirty=1
    fi
  done
  [ "$dirty" -eq 0 ] || fail "shipped catalogue has node-admin exposure absent from node_admin_baseline.txt"
  echo "catalogue: OK (every shipped spec clean or baselined)"
else
  echo "catalogue: SKIP (repo root not found)"
fi

echo "ALL TESTS PASSED"
