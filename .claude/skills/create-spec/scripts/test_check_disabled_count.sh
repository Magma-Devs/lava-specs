#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/check_disabled_count.sh"
F="$DIR/fixtures"
fail() { echo "FAIL: $1" >&2; exit 1; }
# Run the guard without letting a non-zero exit kill this script.
run() { set +e; OUT=$("$SCRIPT" "$@" 2>&1); RC=$?; set -e; }

# --- baseline: file and claim agree -----------------------------------------

run "$F/disabled_count_none.json" --expect 0
[ "$RC" -eq 0 ] || fail "none/0: exit=$RC want 0"
echo "$OUT" | grep -q "RESULT: PASS" || fail "none/0: expected PASS"
echo "none-vs-0: OK"

run "$F/disabled_count_three.json" --expect 3
[ "$RC" -eq 0 ] || fail "three/3: exit=$RC want 0"
echo "$OUT" | grep -q "RESULT: PASS" || fail "three/3: expected PASS"
for m in a_one a_three a_four; do
  echo "$OUT" | grep -q "$m" || fail "three/3: expected $m in the report"
done
echo "$OUT" | grep -q "a_two" && fail "three/3: a_two is enabled, must not be listed"
echo "three-vs-3: OK"

# --- the two shapes that motivated the guard --------------------------------

# #125: body said 12, file disabled 15.
run "$F/disabled_count_three.json" --expect 12
[ "$RC" -eq 1 ] || fail "three/12: exit=$RC want 1"
echo "$OUT" | grep -q "MISMATCH | claimed=12 | actual=3" || fail "three/12: expected the MISMATCH row"
echo "three-vs-12: OK"

# #130: body said "No method disabled anywhere", file disabled 13.
run "$F/disabled_count_three.json" --body "$F/disabled_count_body_zero.md"
[ "$RC" -eq 1 ] || fail "body-zero: exit=$RC want 1"
echo "$OUT" | grep -q "claimed=0" || fail "body-zero: expected claimed=0 parsed from the body"
echo "body-zero-vs-three: OK"

run "$F/disabled_count_three.json" --body "$F/disabled_count_body_three.md"
[ "$RC" -eq 0 ] || fail "body-three: exit=$RC want 0"
echo "$OUT" | grep -q "RESULT: PASS" || fail "body-three: expected PASS"
echo "body-three-vs-three: OK"

# --- report-only is for the no-argument form ONLY ---------------------------

run "$F/disabled_count_three.json"
[ "$RC" -eq 0 ] || fail "no-claim: exit=$RC want 0"
echo "$OUT" | grep -q "RESULT: PASS (report only)" || fail "no-claim: expected report-only PASS"
echo "no-claim: OK"

# A --body whose claim does not parse is a failure to verify, not a pass. This
# is the fail-open the guard existed to prevent: "Disabled 13 methods from the
# author_* family" is a plausible Phase 11 phrasing and used to exit 0.
run "$F/disabled_count_three.json" --body "$F/disabled_count_body_unparseable.md"
[ "$RC" -eq 2 ] || fail "unparseable-body: exit=$RC want 2 (fail-open regression)"
echo "$OUT" | grep -q "COULD NOT PARSE A CLAIM" || fail "unparseable-body: expected the unverifiable row"
echo "unparseable-body-fails-closed: OK"

# An unset CI variable reaching --expect must not degrade to report-only either.
run "$F/disabled_count_three.json" --expect ""
[ "$RC" -eq 2 ] || fail "empty-expect: exit=$RC want 2"
echo "$OUT" | grep -q "COULD NOT PARSE A CLAIM" || fail "empty-expect: expected the unverifiable row"
echo "empty-expect-fails-closed: OK"

# A flag with no value at all is a usage error (2), not a mismatch (1).
run "$F/disabled_count_three.json" --expect
[ "$RC" -eq 2 ] || fail "missing-flag-value: exit=$RC want 2"
echo "missing-flag-value: OK"

# --- a body that contradicts itself is not a pass ---------------------------

# `ledger is empty` used to match the ARCHIVE ledger and short-circuit the count
# branch, so a body claiming 3 against a file disabling 0 passed green. Anchoring
# the phrase to the disabled-API ledger lets the stated count be read instead.
run "$F/disabled_count_none.json" --body "$F/disabled_count_body_loose_ledger.md"
[ "$RC" -eq 1 ] || fail "loose-ledger: exit=$RC want 1 (zero-phrase short-circuit regression)"
echo "$OUT" | grep -q "claimed=3 | actual=0" || fail "loose-ledger: expected the stated count to win"
echo "loose-ledger-does-not-zero: OK"

# When a genuine zero-phrase and an explicit count both appear, neither half can
# be trusted — that is a contradiction to report, not a value to pick.
run "$F/disabled_count_three.json" --body "$F/disabled_count_body_conflict.md"
[ "$RC" -eq 1 ] || fail "conflict: exit=$RC want 1"
echo "$OUT" | grep -q "CONFLICT" || fail "conflict: expected the CONFLICT row"
echo "self-contradictory-body: OK"

# --- a corrected PR must not false-FAIL -------------------------------------

# All three motivating PRs were fixed in place with a strikethrough plus a
# revision note. Reading the struck 12 would block correct work.
run "$F/disabled_count_none.json" --body "$F/disabled_count_body_struck.md"
[ "$RC" -eq 0 ] || fail "struck: exit=$RC want 0 (strikethrough regression)"
echo "$OUT" | grep -q "RESULT: PASS" || fail "struck: expected PASS"
echo "struck-revision: OK"

# --- the marker wins over prose ---------------------------------------------

# The body's prose contains "Auto-decision 6: **3 methods shipped enabled:
# false**"; the marker is the value actually compared.
run "$F/disabled_count_three.json" --body "$F/disabled_count_body_marker.md"
[ "$RC" -eq 0 ] || fail "marker: exit=$RC want 0"
echo "$OUT" | grep -q "disabled-count marker" || fail "marker: expected the marker to be the source"
echo "marker-preferred: OK"

# --- multi-entry specs count methods, not rows ------------------------------

# secret.json / starknet.json declare the full API set on both spec entries, so
# disabling one method writes two rows. A body says "1 method".
run "$F/disabled_count_two_entries.json" --expect 1
[ "$RC" -eq 0 ] || fail "two-entries: exit=$RC want 0 (double-count regression)"
echo "$OUT" | grep -q "1 distinct method(s), 2 row(s)" || fail "two-entries: expected both counts reported"
echo "two-entries-counts-methods: OK"

# --- malformed input fails closed -------------------------------------------

echo 'not json' > /tmp/dc_bad.json
run /tmp/dc_bad.json --expect 0
[ "$RC" -eq 2 ] || fail "bad-json: exit=$RC want 2"
echo "bad-json: OK"

# Syntactically valid JSON of the wrong shape used to read as "0 disabled".
run "$F/disabled_count_wrong_shape.json" --expect 0
[ "$RC" -eq 2 ] || fail "wrong-shape: exit=$RC want 2 (silent-traversal regression)"
echo "$OUT" | grep -q "UNEXPECTED_SHAPE" || fail "wrong-shape: expected the UNEXPECTED_SHAPE row"
echo "wrong-shape: OK"

echo "ALL TESTS PASSED"
