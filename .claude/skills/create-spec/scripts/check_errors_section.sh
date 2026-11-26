#!/usr/bin/env bash
# check_errors_section.sh — guard for a spec's `errors` section: the per-chain error rows,
# shapes and write rows smart-router reads (its per-chain error classification design, PRD on
# Magma-Devs/smart-router#661).
#
# A spec's error rows each carry their own evidence and approvals (a pinned node-software
# source, a reply per matcher, product's approval of every write verdict). Nothing in this
# skill may change them as a side effect: not a regeneration, not a fix pass, not a template
# copied into a new chain. This guard makes that checkable.
#
#   check_errors_section.sh preserve <base.json> <candidate.json>
#       Every spec index present in BOTH files has the same `errors` section in each, compared
#       in jq -S canonical form (key order and whitespace are ignored; every value, every
#       added or removed field and every row or shape reorder is caught: the first matching
#       row wins, so order is meaning). An absent section equals an absent section. A spec
#       only base holds may not have carried a section: dropping the spec drops its rows. A
#       spec only candidate holds may not carry one: a new spec gets its family's rows
#       through `imports`. Whether such a spec may come or go at all is other guards' business
#       (check_preservation.sh and friends).
#
#   check_errors_section.sh none <candidate.json>
#       No spec in candidate carries an `errors` section. For a file create-spec wrote
#       itself: it does not write error rows, and a chain's family rows reach it through
#       `imports`, never as a copy.
#
# Exit: 0 PASS · 1 FAIL · 2 usage or unparseable input.
set -euo pipefail

usage() {
  echo "usage: $0 preserve <base.json> <candidate.json> | $0 none <candidate.json>" >&2
  exit 2
}

readable() {
  local f="$1"
  [[ -r "$f" ]] || { echo "cannot read: $f" >&2; echo "RESULT: FAIL (unreadable: $f)"; exit 2; }
  [[ -s "$f" ]] || { echo "INVALID_JSON | $f (empty)" >&2; echo "RESULT: FAIL (empty file: $f)"; exit 2; }
  jq empty "$f" 2>/dev/null || { echo "INVALID_JSON | $f" >&2; echo "RESULT: FAIL (invalid JSON: $f)"; exit 2; }
}

PASS=()
FAIL=()

report() {
  echo "=== PASS ==="
  printf '%s\n' ${PASS[@]+"${PASS[@]}"}
  echo "=== FAIL ==="
  printf '%s\n' ${FAIL[@]+"${FAIL[@]}"}
  if [[ ${#FAIL[@]} -eq 0 ]]; then
    echo "RESULT: PASS"
    exit 0
  fi
  echo "RESULT: FAIL (${#FAIL[@]} finding(s))"
  exit 1
}

[[ $# -ge 1 ]] || usage
mode="$1"
shift

case "$mode" in
  preserve)
    [[ $# -eq 2 ]] || usage
    BASE="$1"
    CAND="$2"
    readable "$BASE"
    readable "$CAND"
    while IFS= read -r idx; do
      [[ -z "$idx" ]] && continue
      # "[]": the file has no spec with this index. "[null]": it has one, with no section.
      b=$(jq -S -c --arg i "$idx" '[.proposal.specs[]? | select(.index == $i) | .errors]' "$BASE")
      c=$(jq -S -c --arg i "$idx" '[.proposal.specs[]? | select(.index == $i) | .errors]' "$CAND")
      if [[ "$c" == "[]" ]]; then
        if [[ "$b" == "[null]" ]]; then
          PASS+=("removed|$idx|candidate removes a spec that had no errors section")
        else
          FAIL+=("spec-dropped|$idx|candidate removes a spec that carries an errors section, and its rows with it")
        fi
      elif [[ "$b" == "[]" ]]; then
        if [[ "$c" == "[null]" ]]; then
          PASS+=("new|$idx|candidate's new spec carries no errors section")
        else
          FAIL+=("added|$idx|candidate's new spec carries an errors section; a new spec gets its family's rows through imports")
        fi
      elif [[ "$b" == "$c" ]]; then
        if [[ "$b" == "[null]" ]]; then
          PASS+=("absent|$idx|no errors section in either")
        else
          PASS+=("preserved|$idx|errors section unchanged")
        fi
      elif [[ "$b" == "[null]" ]]; then
        FAIL+=("added|$idx|candidate adds an errors section the base does not have")
      elif [[ "$c" == "[null]" ]]; then
        FAIL+=("dropped|$idx|candidate drops the base's errors section")
      else
        FAIL+=("changed|$idx|candidate changes the errors section (a value, a field, or the order of rows or shapes)")
      fi
    done < <(jq -r '.proposal.specs[]?.index | strings' "$BASE" "$CAND" | LC_ALL=C sort -u)
    report
    ;;
  none)
    [[ $# -eq 1 ]] || usage
    CAND="$1"
    readable "$CAND"
    while IFS= read -r idx; do
      [[ -z "$idx" ]] && continue
      FAIL+=("present|$idx|create-spec writes no errors section; family rows arrive through imports")
    done < <(jq -r '.proposal.specs[]? | select(has("errors")) | .index' "$CAND")
    [[ ${#FAIL[@]} -eq 0 ]] && PASS+=("none|ok|no spec carries an errors section")
    report
    ;;
  *)
    usage
    ;;
esac
