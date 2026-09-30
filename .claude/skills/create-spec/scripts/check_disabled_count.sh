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
# separate guard (MAG-3343). It only enforces that the file and the body agree.
#
# The claim comes from one of three places, in precedence order:
#
#   1. --expect <N>                        explicit, exact
#   2. `<!-- disabled-count: N -->`        machine-readable marker in the body,
#                                          the same shape as the `<!-- ENDPOINTS`
#                                          marker resolve_endpoints.sh already
#                                          parses. Exact — no regex over prose.
#   3. prose in the body                   fallback for bodies with no marker
#
# The prose parser is a fallback, not the contract: LLM phrasing is not stable,
# so anything it cannot resolve is a FAILURE TO VERIFY (exit 2), never a pass.
# Only the no-argument form reports without asserting.
#
# Usage:
#   check_disabled_count.sh <spec.json> --body <pr_body.md>
#   check_disabled_count.sh <spec.json> --expect <N>
#   check_disabled_count.sh <spec.json>            # report only, never fails
#
# Exit: 0 PASS/report · 1 mismatch or self-contradictory body · 2 usage,
#       unparseable input, or a requested claim that could not be resolved.
set -euo pipefail
export LC_ALL=C

SPEC=""; BODY=""; EXPECT=""; CLAIM_REQUESTED=0
need_value() { [[ $# -ge 2 ]] || { echo "flag $1 requires a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --body)   need_value "$@"; BODY="$2";   CLAIM_REQUESTED=1; shift 2 ;;
    --expect) need_value "$@"; EXPECT="$2"; CLAIM_REQUESTED=1; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  SPEC="$1"; shift ;;
  esac
done
[[ -n "$SPEC" ]] || { echo "usage: $0 <spec.json> [--body <pr_body.md> | --expect <N>]" >&2; exit 2; }
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 2; }
jq empty "$SPEC" 2>/dev/null || { echo "INVALID_JSON | $SPEC" >&2; echo "RESULT: FAIL (invalid JSON)"; exit 2; }

# `jq empty` proves syntactic validity only. Without this, a valid JSON that has
# no `.proposal.specs` makes the traversal below print "Cannot iterate over
# null" to stderr inside a process substitution — where neither `set -e` nor
# pipefail sees it — and the wrong shape reads as "0 disabled" and PASSes.
jq -e '.proposal.specs | type == "array"' "$SPEC" >/dev/null 2>&1 || {
  echo "UNEXPECTED_SHAPE | $SPEC has no .proposal.specs array" >&2
  echo "RESULT: FAIL (unexpected spec shape)"; exit 2; }

# Actual disabled set, one row per (spec entry, api name). `mapfile` is bash 4+
# and macOS ships 3.2, so read the rows in a loop instead — SKILL.md documents
# these scripts as local `bash .claude/skills/...` invocations.
ROWS=()
while IFS= read -r line; do [[ -n "$line" ]] && ROWS+=("$line"); done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.apis[]? | select(.enabled == false)
  | "\($s.index)\t\(.name)"' "$SPEC")
ROW_COUNT=${#ROWS[@]}

# A body says "13 methods are disabled", counting METHODS. Most specs declare
# their APIs on one entry and inherit the rest, so rows == methods — but
# secret.json and starknet.json declare the full set on both the mainnet and the
# testnet entry, where disabling one method writes two rows. Compare the claim
# against distinct method names so those two files don't false-FAIL at 2N.
if [[ $ROW_COUNT -gt 0 ]]; then
  ACTUAL=$(printf '%s\n' "${ROWS[@]}" | cut -f2 | sort -u | wc -l | tr -d ' ')
else
  ACTUAL=0
fi

echo "=== DISABLED IN FILE ($ACTUAL distinct method(s), $ROW_COUNT row(s)) ==="
if [[ $ROW_COUNT -eq 0 ]]; then
  echo "(none)"
else
  printf '%s\n' "${ROWS[@]}" | sed 's/^/  /'
fi
echo

# ---------------------------------------------------------------------------
# Claim resolution
# ---------------------------------------------------------------------------
CLAIM=""; SOURCE=""; CONFLICT=""
if [[ -n "$EXPECT" ]]; then
  [[ "$EXPECT" =~ ^[0-9]+$ ]] || { echo "--expect must be an integer (got: '$EXPECT')" >&2; exit 2; }
  CLAIM="$EXPECT"; SOURCE="--expect"
elif [[ -n "$BODY" ]]; then
  [[ -r "$BODY" ]] || { echo "cannot read body: $BODY" >&2; exit 2; }

  # All three motivating PRs were corrected in place with a strikethrough plus a
  # revision note — the normal shape of a *fixed* PR here. Reading the struck
  # number would block correct work, so drop ~~…~~ spans before parsing.
  SANITIZED=$(sed 's/~~[^~]*~~//g' "$BODY")

  MARKER=$(printf '%s\n' "$SANITIZED" | grep -oiE '<!-- *disabled-count: *[0-9]+ *-->' | tail -1 | grep -oE '[0-9]+' || true)
  if [[ -n "$MARKER" ]]; then
    CLAIM="$MARKER"; SOURCE="$BODY (disabled-count marker)"
  else
    # "No method disabled anywhere" / "nothing is disabled" / an empty ledger.
    # `ledger is empty` unanchored matched the archive ledger, the verification
    # ledger, anything — and won before the count branch ran, so a body claiming
    # 13 against a file disabling 0 passed green. Anchor it to the disabled-API
    # ledger by name.
    ZERO=""
    if printf '%s\n' "$SANITIZED" | grep -qiE 'no (method|api)s? +(is +|are +)?disabled|nothing is disabled|disabled-api[^.]{0,40}(ledger )?is empty|ledger of disabled apis is empty'; then
      ZERO=0
    fi
    # "<N> methods/APIs ... enabled: false". The number must be immediately
    # followed by methods/APIs — without that anchor the pattern happily matches
    # the "6" in "Auto-decision 6: **3 methods shipped `enabled: false`**".
    # Revisions append, so take the LAST match, not the first.
    COUNT=$(printf '%s\n' "$SANITIZED" | grep -oiE '[0-9]+ +(methods?|apis?)[^.]{0,40}enabled: *`?false' | tail -1 | grep -oE '^[0-9]+' || true)

    if [[ -n "$ZERO" && -n "$COUNT" && "$COUNT" != "0" ]]; then
      CONFLICT="the body both declares nothing disabled and states a count of $COUNT"
    elif [[ -n "$ZERO" ]]; then
      CLAIM=0; SOURCE="$BODY (zero-phrase)"
    elif [[ -n "$COUNT" ]]; then
      CLAIM="$COUNT"; SOURCE="$BODY (prose count)"
    fi
  fi
fi

if [[ -n "$CONFLICT" ]]; then
  echo "CONFLICT | $CONFLICT"
  echo "RESULT: FAIL (the body contradicts itself; it cannot be checked against the file)"
  exit 1
fi

if [[ -z "$CLAIM" && $CLAIM_REQUESTED -eq 1 ]]; then
  # A claim was asked for and none resolved. That is a failure to verify, not a
  # pass — the old code reported PASS here, which fails open on the one axis the
  # guard exists for. Also catches `--expect ""` from an unset CI variable.
  echo "COULD NOT PARSE A CLAIM | no disabled-count marker, zero-phrase or prose count found"
  echo "HINT: have the body carry '<!-- disabled-count: $ACTUAL -->', or pass --expect <N>"
  echo "RESULT: FAIL (unverifiable)"
  exit 2
fi

if [[ -z "$CLAIM" ]]; then
  echo "INFO: no claim supplied — reporting only, not asserting"
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
