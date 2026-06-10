#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_extensions.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

OUT=$("$SCRIPT" "$DIR/fixtures/extensions_good.json")
F=$(echo "$OUT" | awk '/^=== FAIL/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$F" -eq 0 ] || fail "good: FAIL rows=$F, want 0"
echo "good: OK"

set +e; OUT=$("$SCRIPT" "$DIR/fixtures/extensions_bad.json"); RC=$?; set -e
[ "$RC" -eq 1 ] || fail "bad: exit=$RC, want 1"
F=$(echo "$OUT" | awk '/^=== FAIL/{f=1;next} /^=== /{f=0} f && NF' | wc -l)
[ "$F" -ge 3 ] || fail "bad: FAIL rows=$F, want >=3"
echo "bad: OK"

echo "ALL TESTS PASSED"
