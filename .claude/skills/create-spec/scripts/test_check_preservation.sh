#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_preservation.sh"
BASE="$DIR/fixtures/preservation_base.json"
fail() { echo "FAIL: $1" >&2; exit 1; }

# run <fixture> <new_index> -> sets RC and OUT
run() {
  set +e
  OUT="$("$SCRIPT" "$BASE" "$DIR/fixtures/$1" "$2" 2>&1)"
  RC=$?
  set -e
}

# 1) good — only MAINT2 added, everything else preserved: exit 0
run preservation_good.json MAINT2
[ "$RC" -eq 0 ] || fail "good: exit=$RC want 0 ($OUT)"
echo "$OUT" | grep -q "RESULT: PASS" || fail "good: no PASS result"
echo "good: OK"

# 2) drift — MAIN's average_block_time silently changed: exit 1, modified-spec|MAIN
run preservation_drift.json MAINT2
[ "$RC" -eq 1 ] || fail "drift: exit=$RC want 1"
echo "$OUT" | grep -q "modified-spec|MAIN" || fail "drift: missing modified-spec|MAIN ($OUT)"
echo "drift: OK"

# 3) extrakey — a top-level deposit reintroduced: exit 1, top-level-keys|changed
run preservation_extrakey.json MAINT2
[ "$RC" -eq 1 ] || fail "extrakey: exit=$RC want 1"
echo "$OUT" | grep -q "top-level-keys|changed" || fail "extrakey: missing top-level-keys|changed ($OUT)"
echo "extrakey: OK"

# 4) twonew — two specs added when only MAINT2 allowed: exit 1, unexpected-new-spec|MAINT3
run preservation_twonew.json MAINT2
[ "$RC" -eq 1 ] || fail "twonew: exit=$RC want 1"
echo "$OUT" | grep -q "unexpected-new-spec|MAINT3" || fail "twonew: missing unexpected-new-spec|MAINT3 ($OUT)"
echo "twonew: OK"

# 5) noimport — added testnet has no imports: exit 1, no-imports|MAINT2
run preservation_noimport.json MAINT2
[ "$RC" -eq 1 ] || fail "noimport: exit=$RC want 1"
echo "$OUT" | grep -q "no-imports|MAINT2" || fail "noimport: missing no-imports|MAINT2 ($OUT)"
echo "noimport: OK"

# 6) removed — a pre-existing testnet dropped: exit 1, removed-spec|MAINT
run preservation_removed.json MAINT2
[ "$RC" -eq 1 ] || fail "removed: exit=$RC want 1"
echo "$OUT" | grep -q "removed-spec|MAINT" || fail "removed: missing removed-spec|MAINT ($OUT)"
echo "removed: OK"

# 7) missing new index — NEW_INDEX not actually added: exit 1, missing-new-spec
run preservation_good.json NOPE
[ "$RC" -eq 1 ] || fail "missing: exit=$RC want 1"
echo "$OUT" | grep -q "missing-new-spec|NOPE" || fail "missing: missing-new-spec|NOPE ($OUT)"
# MAINT2 is now an unexpected add relative to NEW_INDEX=NOPE
echo "$OUT" | grep -q "unexpected-new-spec|MAINT2" || fail "missing: MAINT2 should be unexpected ($OUT)"
echo "missing: OK"

# 8) usage — wrong arg count: exit 2
set +e; "$SCRIPT" "$BASE" >/dev/null 2>&1; RC=$?; set -e
[ "$RC" -eq 2 ] || fail "usage: exit=$RC want 2"
echo "usage: OK"

# 9) invalid JSON candidate — fail closed: exit 2
BAD="$(mktemp)"; printf '{not json' > "$BAD"
set +e; OUT="$("$SCRIPT" "$BASE" "$BAD" MAINT2 2>&1)"; RC=$?; set -e
rm -f "$BAD"
[ "$RC" -eq 2 ] || fail "invalid: exit=$RC want 2 ($OUT)"
echo "invalid: OK"

echo "ALL TESTS PASSED"
