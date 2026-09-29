#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_collection_addition.sh"
BASE="$DIR/fixtures/colladd_base.json"
fail() { echo "FAIL: $1" >&2; exit 1; }

# run <fixture> [allowed_indexes] -> sets RC and OUT
run() {
  set +e
  if [ $# -ge 2 ]; then
    OUT="$("$SCRIPT" "$BASE" "$DIR/fixtures/$1" "$2" 2>&1)"
  else
    OUT="$("$SCRIPT" "$BASE" "$DIR/fixtures/$1" 2>&1)"
  fi
  RC=$?
  set -e
}

# 1) good — MAIN gains one rest/GET collection, nothing else moves: exit 0
run colladd_good.json MAIN
[ "$RC" -eq 0 ] || fail "good: exit=$RC want 0 ($OUT)"
echo "$OUT" | grep -q "RESULT: PASS" || fail "good: no PASS result"
echo "$OUT" | grep -q "added-collection|MAIN|rest" || fail "good: addition not itemized ($OUT)"
echo "good: OK"

# 2) good without an index allowlist — still passes, still guards
run colladd_good.json
[ "$RC" -eq 0 ] || fail "good-noallow: exit=$RC want 0 ($OUT)"
echo "good-noallow: OK"

# 3) specdrift — average_block_time changed alongside the addition: exit 1
run colladd_specdrift.json MAIN
[ "$RC" -eq 1 ] || fail "specdrift: exit=$RC want 1"
echo "$OUT" | grep -q "modified-spec-fields|MAIN" || fail "specdrift: missing modified-spec-fields|MAIN ($OUT)"
echo "specdrift: OK"

# 4) collmodified — the pre-existing jsonrpc collection was edited: exit 1
run colladd_collmodified.json MAIN
[ "$RC" -eq 1 ] || fail "collmodified: exit=$RC want 1"
echo "$OUT" | grep -q "modified-collection|MAIN|jsonrpc" || fail "collmodified: missing modified-collection ($OUT)"
echo "collmodified: OK"

# 5) collremoved — a pre-existing collection dropped: exit 1
run colladd_collremoved.json MAIN
[ "$RC" -eq 1 ] || fail "collremoved: exit=$RC want 1"
echo "$OUT" | grep -q "removed-collection|MAIN|jsonrpc" || fail "collremoved: missing removed-collection ($OUT)"
echo "collremoved: OK"

# 6) noop — nothing added; a mis-invocation, not a pass: exit 1
run colladd_noop.json MAIN
[ "$RC" -eq 1 ] || fail "noop: exit=$RC want 1"
echo "$OUT" | grep -q "no-collection-added" || fail "noop: missing no-collection-added ($OUT)"
echo "noop: OK"

# 7) addedspec — a whole spec entry appeared: exit 1 (that is add-testnet's job)
run colladd_addedspec.json MAIN
[ "$RC" -eq 1 ] || fail "addedspec: exit=$RC want 1"
echo "$OUT" | grep -q "added-spec|MAINT2" || fail "addedspec: missing added-spec|MAINT2 ($OUT)"
echo "addedspec: OK"

# 8) wrongindex — collection landed on MAINT while only MAIN was allowed: exit 1
run colladd_wrongindex.json MAIN
[ "$RC" -eq 1 ] || fail "wrongindex: exit=$RC want 1"
echo "$OUT" | grep -q "unexpected-collection|MAINT" || fail "wrongindex: missing unexpected-collection|MAINT ($OUT)"
echo "wrongindex: OK"

# 9) wrongindex is legitimate when MAINT is allowed: exit 0
run colladd_wrongindex.json MAIN,MAINT
[ "$RC" -eq 0 ] || fail "wrongindex-allowed: exit=$RC want 0 ($OUT)"
echo "wrongindex-allowed: OK"

# 10) envelope — a stray top-level deposit reintroduced: exit 1
run colladd_envelope.json MAIN
[ "$RC" -eq 1 ] || fail "envelope: exit=$RC want 1"
echo "$OUT" | grep -q "top-level-keys|changed" || fail "envelope: missing top-level-keys|changed ($OUT)"
echo "envelope: OK"

# 11) usage — wrong arg count: exit 2
set +e
OUT="$("$SCRIPT" "$BASE" 2>&1)"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "usage: exit=$RC want 2"
echo "usage: OK"

# 12) unparseable candidate must fail closed, never pass
set +e
OUT="$("$SCRIPT" "$BASE" /dev/null 2>&1)"; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "invalid-json: exit=$RC want 2"
echo "$OUT" | grep -q "RESULT: FAIL" || fail "invalid-json: did not fail closed ($OUT)"
echo "invalid-json: OK"

echo "ALL TESTS PASSED"
