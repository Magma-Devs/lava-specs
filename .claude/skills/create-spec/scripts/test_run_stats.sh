#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/run_stats.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Use a real transcript dir if available; otherwise synthesize a minimal one.
# Tests must not depend on a specific live session, so build a fixture dir.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SID="test-session"
# Two assistant usage lines: one BEFORE the start threshold (must be excluded),
# one AFTER (must be counted). Plus a subagent transcript with one AFTER line.
cat > "$TMP/$SID.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":111,"output_tokens":11,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100}}}
{"type":"assistant","timestamp":"2026-01-01T01:00:00.500Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":50,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300}}}
EOF
mkdir -p "$TMP/$SID/subagents"
cat > "$TMP/$SID/subagents/agent-aaa.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T01:05:00.123Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":40,"output_tokens":9,"cache_read_input_tokens":500,"cache_creation_input_tokens":25}}}
EOF

# Start threshold = 2026-01-01T00:30:00Z → excludes line 1, includes line 2 + subagent.
START=$(date -d "2026-01-01T00:30:00Z" +%s)

# Case 1: usage filtered + summed across main + subagents
OUT=$("$SCRIPT" "$START" "$TMP")
echo "$OUT" | grep -q "1 main + 1 subagent" || fail "expected 1 main + 1 subagent"
# input: 200 (main) + 40 (sub) = 240 ; the excluded line's 111 must NOT appear
echo "$OUT" | grep -q "input=240" || fail "expected input=240 (excluded pre-start line?)"
echo "$OUT" | grep -q "output=59" || fail "expected output=59"
# total billed = (200+50+2000+300) + (40+9+500+25) = 2550 + 574 = 3124
echo "$OUT" | grep -q "Total billed:    3124 tokens" || fail "expected total 3124; got: $OUT"
echo "$OUT" | grep -qE "API round-trips: 2  \(main=1, subagents=1\)" || fail "expected 2 calls 1/1"
# elapsed = last in-window ts (01:05:00 subagent) − first (01:00:00 main) = 5m00s
echo "$OUT" | grep -q "Elapsed:         00h 05m 00s" || fail "expected elapsed 5m; got: $OUT"
# per-model breakdown: opus (main, 1 call, billed 2550) + sonnet (sub, 1 call, billed 574)
echo "$OUT" | grep -qE "claude-opus-4-8 +1 calls +2550 billed" || fail "expected opus row; got: $OUT"
echo "$OUT" | grep -qE "claude-sonnet-4-6 +1 calls +574 billed" || fail "expected sonnet row; got: $OUT"
echo "case1 (filter+sum+split+models): OK"

# Case 2: no subagents dir → 0 subagents, main only
rm -rf "$TMP/$SID"
OUT=$("$SCRIPT" "$START" "$TMP")
echo "$OUT" | grep -q "1 main + 0 subagent" || fail "expected 0 subagents"
echo "$OUT" | grep -q "input=200" || fail "expected input=200 main-only"
echo "case2 (no subagents): OK"

# Case 3: bad start arg → usage error, exit 2
set +e
"$SCRIPT" notanint "$TMP" >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 2 ] || fail "bad start: exit=$RC want 2"
echo "case3 (bad arg): OK"

# Case 4: missing transcript dir → exit 1
set +e
"$SCRIPT" "$START" "$TMP/does-not-exist" >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 1 ] || fail "missing dir: exit=$RC want 1"
echo "case4 (missing dir): OK"

echo "ALL TESTS PASSED"
