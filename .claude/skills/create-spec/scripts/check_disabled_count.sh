#!/usr/bin/env bash
# check_disabled_count.sh — the file's `enabled: false` set must match what the
# PR body claims about it.
#
# Three specs in the Kraken batch shipped a body and a file that disagreed about
# disabling, and nothing compared them:
#
#   PR #125 (lit.json)  body said 12, file disabled 15
#   PR #128 (xrt.json)  body's evidence held for 2 of the 14 it disabled
#   PR #130 (enj.json)  body said "No method disabled anywhere", file disabled 13
#                       — and the SAME pipeline run wrote both halves: the Phase
#                       10 fixer introduced the 13 (commit 79908be) after the
#                       Phase 11 body had already declared zero.
#
# The Phase 10 fixer is instructed in SKILL.md never to set `enabled: false`
# without a positive-evidence ledger row. It did so three times out of three, so
# a prompt instruction is not sufficient and this checks the artifact instead.
#
# Deliberately OFFLINE: no endpoint, no probing, no rate limits. It does not
# judge whether a disable is *justified* — that needs a live probe and is a
# separate guard. It only enforces that the file and the body agree, which is
# the failure a validator, a reviewer and a human all missed on #130.
#
# Usage:
#   check_disabled_count.sh <spec.json> --body <pr_body.md>
#   check_disabled_count.sh <spec.json> --expect <N>
#   check_disabled_count.sh <spec.json>            # report only, never fails
#
# Exit: 0 PASS/report · 1 mismatch · 2 usage or unparseable input.
set -euo pipefail
export LC_ALL=C

SPEC=""; BODY=""; EXPECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --body)   BODY="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  SPEC="$1"; shift ;;
  esac
done
[[ -n "$SPEC" ]] || { echo "usage: $0 <spec.json> [--body <pr_body.md> | --expect <N>]" >&2; exit 2; }
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 2; }
jq empty "$SPEC" 2>/dev/null || { echo "INVALID_JSON | $SPEC" >&2; echo "RESULT: FAIL (invalid JSON)"; exit 2; }

# Actual disabled set, per spec entry.
mapfile -t ROWS < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.apis[]? | select(.enabled == false)
  | "\($s.index)\t\(.name)"' "$SPEC")
ACTUAL=${#ROWS[@]}

echo "=== DISABLED IN FILE ($ACTUAL) ==="
if [[ $ACTUAL -eq 0 ]]; then
  echo "(none)"
else
  printf '%s\n' "${ROWS[@]}" | sed 's/^/  /'
fi
echo

# Claim resolution: --expect wins; else parse the body; else report only.
CLAIM=""; SOURCE=""
if [[ -n "$EXPECT" ]]; then
  [[ "$EXPECT" =~ ^[0-9]+$ ]] || { echo "--expect must be an integer (got: $EXPECT)" >&2; exit 2; }
  CLAIM="$EXPECT"; SOURCE="--expect"
elif [[ -n "$BODY" ]]; then
  [[ -r "$BODY" ]] || { echo "cannot read body: $BODY" >&2; exit 2; }
  SOURCE="$BODY"
  # "No method disabled anywhere" / "nothing is disabled" / "all N ship enabled: true"
  if grep -qiE 'no method[s]? (is |are )?disabled|nothing is disabled|ledger is empty' "$BODY"; then
    CLAIM=0
  else
    # "<N> methods/APIs ... enabled: false". The number must be immediately
    # followed by methods/APIs — without that anchor the pattern happily matches
    # the "6" in "Auto-decision 6: **3 methods shipped `enabled: false`**".
    CLAIM=$(grep -oiE '[0-9]+ +(methods?|apis?)[^.]{0,40}enabled: *`?false' "$BODY" | head -1 | grep -oE '^[0-9]+' || true)
  fi
fi

if [[ -z "$CLAIM" ]]; then
  echo "INFO: no claim supplied or parsed — reporting only, not asserting"
  echo "RESULT: PASS (report only)"
  exit 0
fi

echo "claim: $CLAIM (from $SOURCE)   actual: $ACTUAL"
echo
if [[ "$CLAIM" == "$ACTUAL" ]]; then
  echo "RESULT: PASS (file and claim agree on $ACTUAL disabled)"
  exit 0
fi
echo "MISMATCH | claimed=$CLAIM | actual=$ACTUAL"
echo "RESULT: FAIL (the file disables $ACTUAL, the claim says $CLAIM)"
exit 1
