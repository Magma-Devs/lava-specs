#!/usr/bin/env bash
# Tests for check_errors_section.sh — the `errors` section guard. The fixtures are built from
# preservation_base.json with jq, so each case differs from its base in exactly one way.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_errors_section.sh"
BASE="$DIR/fixtures/preservation_base.json"
T=$(mktemp -d "${TMPDIR:-/tmp}/check_errors_section_test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# run <args...> -> sets RC and OUT
run() {
  set +e
  OUT="$("$SCRIPT" "$@" 2>&1)"
  RC=$?
  set -e
}

ROWS='{"schema_version":1,"rows":[
  {"id":"demo.one","interface":"jsonrpc","code":-32001,"error":"CHAIN_STATE_PRUNED","source":"https://example.invalid/node/v1/errors.go"},
  {"id":"demo.two","interface":"jsonrpc","contains":"not found","error":"CHAIN_BLOCK_NOT_FOUND","source":"https://example.invalid/node/v1/errors.go"}]}'
jq --argjson e "$ROWS" '.proposal.specs[0].errors = $e' "$BASE" > "$T/with.json"

# 1) the same section on both sides, keys in another order: PASS
jq -S . "$T/with.json" > "$T/sorted.json"
run preserve "$T/with.json" "$T/sorted.json"
[ "$RC" -eq 0 ] || fail "preserved: exit=$RC want 0 ($OUT)"
echo "$OUT" | grep -q "preserved|MAIN" || fail "preserved: missing preserved|MAIN ($OUT)"
echo "preserved: OK"

# 2) neither side has one: PASS
run preserve "$BASE" "$BASE"
[ "$RC" -eq 0 ] || fail "absent: exit=$RC want 0 ($OUT)"
echo "$OUT" | grep -q "absent|MAIN" || fail "absent: missing absent|MAIN ($OUT)"
echo "absent: OK"

# 3) a regeneration or a fix pass that drops the section: FAIL
run preserve "$T/with.json" "$BASE"
[ "$RC" -eq 1 ] || fail "dropped: exit=$RC want 1 ($OUT)"
echo "$OUT" | grep -q "dropped|MAIN" || fail "dropped: missing dropped|MAIN ($OUT)"
echo "dropped: OK"

# 4) one that adds a section: FAIL
run preserve "$BASE" "$T/with.json"
[ "$RC" -eq 1 ] || fail "added: exit=$RC want 1 ($OUT)"
echo "$OUT" | grep -q "added|MAIN" || fail "added: missing added|MAIN ($OUT)"
echo "added: OK"

# 5) one value changed: FAIL
jq '.proposal.specs[0].errors.rows[0].code = -32002' "$T/with.json" > "$T/changed.json"
run preserve "$T/with.json" "$T/changed.json"
[ "$RC" -eq 1 ] || fail "changed: exit=$RC want 1 ($OUT)"
echo "$OUT" | grep -q "changed|MAIN" || fail "changed: missing changed|MAIN ($OUT)"
echo "changed: OK"

# 6) the same rows in another order: FAIL — the first matching row wins
jq '.proposal.specs[0].errors.rows |= reverse' "$T/with.json" > "$T/reordered.json"
run preserve "$T/with.json" "$T/reordered.json"
[ "$RC" -eq 1 ] || fail "reordered: exit=$RC want 1 ($OUT)"
echo "$OUT" | grep -q "changed|MAIN" || fail "reordered: missing changed|MAIN ($OUT)"
echo "reordered: OK"

# 7) a spec only one side holds is out of scope here: PASS
jq '.proposal.specs += [{"index":"EXTRA","name":"extra","imports":["MAIN"]}]' "$T/with.json" > "$T/extra.json"
run preserve "$T/with.json" "$T/extra.json"
[ "$RC" -eq 0 ] || fail "extra spec: exit=$RC want 0 ($OUT)"
echo "extra spec: OK"

# 8) none: a file without a section passes, one with a section names the spec
run none "$BASE"
[ "$RC" -eq 0 ] || fail "none clean: exit=$RC want 0 ($OUT)"
run none "$T/with.json"
[ "$RC" -eq 1 ] || fail "none present: exit=$RC want 1 ($OUT)"
echo "$OUT" | grep -q "present|MAIN" || fail "none present: missing present|MAIN ($OUT)"
echo "none: OK"

# 9) usage and unreadable input: exit 2
run preserve "$BASE"
[ "$RC" -eq 2 ] || fail "usage: exit=$RC want 2"
echo '{' > "$T/broken.json"
run none "$T/broken.json"
[ "$RC" -eq 2 ] || fail "invalid json: exit=$RC want 2"
echo "usage: OK"

echo "ALL check_errors_section TESTS PASSED"
