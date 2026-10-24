#!/usr/bin/env bash
# check_chain_identity.sh — can every spec tell a node of its own chain apart
# from a node of another chain in the catalogue?
#
# A spec's verifications are the router's only automatic proof that a configured
# URL serves the chain it claims. That proof holds only if a node of any OTHER
# chain fails them. For every enabled spec and every endpoint shape it serves
# (interface + internal path, base collections only — an add-on is opt-in per
# endpoint), this guard reports:
#
#   UNIDENTIFIED  none of the checks that endpoint must pass compares a value
#                 (no Fail-severity check with an expected value other than
#                 `*`), so a node of any chain passes.
#   UNSEPARATED   every one of those checks is a question another enabled spec
#                 also declares, with the same expected answer, so a node of
#                 that chain passes them all. The guard names which chains.
#
# "The same question" is the same request read the same way: interface, HTTP
# type, api_name, function_template, result_parsing and parsers. It is not the
# check's name, and it is not merely the value. Six unrelated chains answer `1`
# to six different requests; none can pass another's check, and none is
# reported.
#
# Provenance: MAG-2850. getblockchaininfo's `chain` field is the network type,
# so BTC, BCH, DASH, DOGE, LTC and ZCASH all expect `main`: a Dogecoin URL
# configured as BTC boots and serves Dogecoin as Bitcoin, with no error
# anywhere.
#
# Catalogue-wide by nature: one spec's identity only means something against
# every other spec's answers, so adding or changing ANY spec can make an
# untouched one ambiguous. Today's debt lives in the baseline, so a PR answers
# only for what it changes.
#
# Known limit: the catalogue is compared against itself. A check that no other
# spec shares counts as identifying, even when it cannot tell mainnet from a
# testnet the catalogue has no spec for (FUELNETWORK's `{ health }`).
#
# The import expansion lives in chain_identity.jq and mirrors smart-router's
# DoExpandSpec for verifications; test_check_chain_identity.sh pins it against
# output produced by the router itself.
#
# Usage:
#   check_chain_identity.sh [--specs-dir <dir>] [--baseline <file>]
#
# --specs-dir defaults to the repo root and reads <dir>/*.json only, as the
# router does. Exit 0 = clean (or every finding is a known baseline row),
# 1 = a new finding or a stale baseline row, 2 = usage.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQPROG="$SCRIPT_DIR/chain_identity.jq"
SPECS_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BASELINE="$SCRIPT_DIR/chain_identity_baseline.txt"

usage() { echo "usage: $0 [--specs-dir <dir>] [--baseline <file>]" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --specs-dir) [[ $# -ge 2 ]] || usage; SPECS_DIR="$2"; shift 2 ;;
    --baseline)  [[ $# -ge 2 ]] || usage; BASELINE="$2"; shift 2 ;;
    -h|--help)   sed -n '2,47p' "$0"; exit 0 ;;
    *)           usage ;;
  esac
done

[[ -d "$SPECS_DIR" ]] || { echo "not a directory: $SPECS_DIR" >&2; exit 2; }

FILES=()
for f in "$SPECS_DIR"/*.json; do
  [[ -f "$f" ]] && FILES+=("$f")
done
[[ ${#FILES[@]} -gt 0 ]] || { echo "no *.json specs in $SPECS_DIR" >&2; exit 2; }

ROWS="$(mktemp)"
BASE_ROWS="$(mktemp)"
SEEN_ROWS="$(mktemp)"
trap 'rm -f "$ROWS" "$BASE_ROWS" "$SEEN_ROWS"' EXIT

# Fail closed: a spec jq cannot read, or an import that does not resolve, is not
# a clean catalogue.
if ! jq -n -r -f "$JQPROG" "${FILES[@]}" > "$ROWS"; then
  echo "FAIL: could not expand the catalogue in $SPECS_DIR (jq error above)." >&2
  exit 1
fi

# Baseline rows are "<KIND> <INDEX> <interface> <internal_path or ->", one per
# line; `#` comments and blank lines ignored. A row means: known, ticketed, not
# a regression. It does not mean acceptable.
#
# Held in a temp file and matched with `grep -Fxq` rather than a `declare -A`
# map: stock macOS bash is 3.2, which has no associative arrays, and this guard
# is one a reviewer runs by hand (same reasoning as check_node_admin_rpcs.sh).
#
# A row may carry a trailing ` TEMPORARY` token, meaning "expected to go stale,
# the fix is in flight on another branch". It is stripped for matching.
if [[ -n "$BASELINE" && -r "$BASELINE" ]]; then
  while read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    echo "${line% TEMPORARY}" >> "$BASE_ROWS"
  done < "$BASELINE"
fi

N_SPECS=0
N_SHAPES=0
NEW=()
KNOWN=()

# `others` is the trailing field because it is empty on UNIDENTIFIED rows, and
# tab is IFS whitespace — an empty field in the middle would shift every field
# after it.
while IFS=$'\t' read -r kind idx iface path others; do
  case "$kind" in
    CHECKED) N_SPECS="$idx"; N_SHAPES="$iface"; continue ;;
    UNIDENTIFIED|UNSEPARATED) ;;
    *) continue ;;
  esac
  key="$kind $idx $iface $path"
  echo "$key" >> "$SEEN_ROWS"
  row="$key"
  [[ -n "${others:-}" ]] && row="$key   <- passes for: $others"
  if grep -Fxq "$key" "$BASE_ROWS" 2>/dev/null; then
    KNOWN+=("$row")
  else
    NEW+=("$row")
  fi
done < "$ROWS"

echo "Checked $N_SPECS enabled specs, $N_SHAPES endpoint shapes (interface + internal path)."
echo

if [[ ${#KNOWN[@]} -gt 0 ]]; then
  echo "=== KNOWN (on the baseline: pre-existing, ticketed, still wrong) ==="
  printf '%s\n' "${KNOWN[@]}"
  echo
fi

# A baseline row the catalogue no longer produces is STALE, and a stale row is
# not harmless: it would silently re-permit the finding if the fix were ever
# reverted. So the ledger cleans itself — a stale row fails, and the fix is to
# delete it. A TEMPORARY row reports instead, so the merge that fixes it does
# not turn someone else's CI red.
STALE=()
STALE_TEMP=()
if [[ -n "$BASELINE" && -r "$BASELINE" ]]; then
  while read -r line; do
    raw="${line%%#*}"
    raw="$(echo "$raw" | xargs || true)"
    [[ -z "$raw" ]] && continue
    temp=0
    if [[ "$raw" == *" TEMPORARY" ]]; then
      temp=1
      raw="${raw% TEMPORARY}"
    fi
    if ! grep -Fxq "$raw" "$SEEN_ROWS" 2>/dev/null; then
      if [[ $temp -eq 1 ]]; then STALE_TEMP+=("$raw"); else STALE+=("$raw"); fi
    fi
  done < "$BASELINE"
fi

if [[ ${#STALE_TEMP[@]} -gt 0 ]]; then
  echo "=== STALE, TEMPORARY (the in-flight fix landed — delete these rows now) ==="
  printf '%s\n' "${STALE_TEMP[@]}"
  echo
fi

RC=0

if [[ ${#STALE[@]} -gt 0 ]]; then
  RC=1
  echo "=== STALE BASELINE ROWS ==="
  printf '%s\n' "${STALE[@]}"
  cat <<EOF

FAIL: ${#STALE[@]} baseline row(s) describe a finding the catalogue no longer has.
The fix landed, so the row is dead weight — and worse than dead: it would
silently re-permit the finding if the fix were reverted. Delete these rows from
$(basename -- "$BASELINE").

EOF
fi

echo "=== NEW CHAIN-IDENTITY FINDINGS ==="
if [[ ${#NEW[@]} -eq 0 ]]; then
  echo "(none)"
  echo
  if [[ $RC -eq 0 ]]; then
    echo "OK: every enabled spec either identifies its own chain or is a known baseline row."
  fi
  exit $RC
fi

printf '%s\n' "${NEW[@]}"
cat <<EOF

FAIL: ${#NEW[@]} endpoint shape(s) cannot reject a node of another chain.

  UNSEPARATED   a node of each chain after "passes for:" answers every check
                this endpoint runs exactly as this spec expects. A wrong URL for
                one of those chains boots and serves their data as this chain's.
  UNIDENTIFIED  this endpoint runs no Fail-severity check that compares a value,
                so a node of any chain passes.

Resolve per spec, and record the reasoning where the next reader will find it:

  fix       give the spec a check only its own chain answers. For Bitcoin-style
            chains: chain-id = getblockhash at a fixed height with that block's
            hash as the expected value (QTUM and PEP do this), at a height after
            any fork the chain shares history with. Keep the name chain-id —
            fleet skip-verifications lists match names exactly.
  baseline  if it is pre-existing and being fixed under its own ticket, or two
            specs describe one network on purpose, add the row to
            $(basename -- "$BASELINE") WITH the ticket or the reason. A baseline
            row is a debt record, not an exemption.
EOF
exit 1
