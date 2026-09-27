#!/usr/bin/env bash
# check_node_admin_rpcs.sh — a node-operator control must not ship as a baseline relay.
#
# One question: does this spec serve, ENABLED and from a BASE collection
# (add_on ""), a method whose effect is on the node itself rather than on the
# chain it reports? Those methods mutate the operator's node — its view of
# consensus, its peering, its mining, its keys — and the damage is never scoped
# to the caller: the provider then serves the mutated state to every consumer
# paired with it.
#
# Why `add_on ""` is part of the predicate and not an afterthought: an add-on is
# an opt-in boundary a provider can decline. A base collection is not — every
# provider serving the chain over that interface offers the method, and importing
# specs inherit it wholesale via CombineCollections. MAG-3644's own argument
# turns on exactly this, so a method behind a real add-on (e.g. `debug_setHead`
# under `debug`) is out of scope here and reported as INFO.
#
# Provenance: MAG-3644. bch.json served BCHN's parkblock/unparkblock/finalizeblock
# from BCH's base collection, enabled, at ordinary relay pricing. Reproduced on
# BCHN 29.1.0: one `finalizeblock` call on a provider's node strands it on its
# finalized branch permanently — it rejects the honest longer chain with
# `bad-header-finalization` and bans the peers offering it. That reached main
# without anyone objecting, and the review phases only caught it once a reviewer
# was bumped to opus. This gate is so the next one is caught by a script.
#
# NOT in scope, deliberately:
#   - submitblock / submitblocklight. Block submission is arguably legitimate for
#     a mining consumer; it changes CHAIN state, not the node's own view of it.
#     Its typing (stateful/deterministic) is a different question and belongs to
#     the method-schema gate.
#   - Anything behind a non-empty add_on. That is the opt-in boundary working.
#
# Usage:
#   check_node_admin_rpcs.sh <spec.json> [--baseline <file>]
#
# Exit 0 = clean (or every finding is a known baseline row), 1 = new exposure.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="$SCRIPT_DIR/node_admin_baseline.txt"
SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    -*)         echo "unknown flag: $1" >&2; exit 2 ;;
    *)          SPEC="$1"; shift ;;
  esac
done

[[ -n "$SPEC" ]] || { echo "usage: $0 <spec.json> [--baseline <file>]" >&2; exit 2; }
[[ -r "$SPEC" ]] || { echo "cannot read spec: $SPEC" >&2; exit 1; }

# The controls. Grouped by what an attacker gets, because the groups differ in
# kind and a reader deciding "is my new method one of these?" needs the reason,
# not the list.
#
#   consensus view  — the node's own idea of which chain is real. A consumer
#                     moves the provider's tip, or pins it so it cannot follow
#                     the network. This is the MAG-3644 class.
#   peering         — who the node talks to. Isolate it and its tip goes stale
#                     without any consensus-level tampering at all.
#   lifecycle       — turn the node, or its RPC surface, off.
#   mining          — whose address gets the rewards, and whether mining runs.
#   keys            — accounts and signing ON THE PROVIDER'S NODE. The entire
#                     `personal_` namespace: unlock, import a raw key, send a
#                     transaction from the node's own wallet.
#   regtest mining  — `generate*` fabricates blocks. Harmless on regtest, which
#                     is not what a mainnet spec is serving.
NODE_ADMIN_RE='^('
NODE_ADMIN_RE+='parkblock|unparkblock|finalizeblock'                  # consensus view (BCHN)
NODE_ADMIN_RE+='|invalidateblock|reconsiderblock|preciousblock'       # consensus view (Core family)
NODE_ADMIN_RE+='|debug_setHead|debug_setGCPercent'                    # consensus view / runtime (geth)
NODE_ADMIN_RE+='|addnode|disconnectnode|setban|clearbanned|setnetworkactive'  # peering
NODE_ADMIN_RE+='|admin_addPeer|admin_removePeer|admin_addTrustedPeer|admin_removeTrustedPeer'
NODE_ADMIN_RE+='|stop|admin_startHTTP|admin_stopHTTP|admin_startWS|admin_stopWS|admin_startRPC|admin_stopRPC'  # lifecycle
NODE_ADMIN_RE+='|miner_start|miner_stop|miner_setEtherbase|miner_setGasPrice|miner_setExtra|miner_setRecommitInterval'  # mining
NODE_ADMIN_RE+='|generate|generatetoaddress|generatetodescriptor|setgenerate'  # regtest mining
NODE_ADMIN_RE+=')$'
# The `personal_` namespace is matched by prefix — it is uniformly key material,
# and enumerating it invites the list to fall behind a client release.
NODE_ADMIN_PREFIX_RE='^personal_'

# Baseline rows are "<spec-basename> <INDEX> <interface> <method>", one per line;
# `#` comments and blank lines ignored. A row means: known, ticketed, not a
# regression. It does not mean acceptable.
#
# Held in a temp file and matched with `grep -Fxq` rather than a `declare -A`
# map: stock macOS bash is 3.2, which has no associative arrays, and this guard
# is one a reviewer runs by hand against a PR (same reasoning as
# check_disabled_count.sh — see TESTING.md).
#
# A row may carry a trailing ` TEMPORARY` token, meaning "expected to go stale,
# the fix is in flight on another branch". It is stripped for matching.
BASE_ROWS="$(mktemp)"
SEEN_ROWS="$(mktemp)"
trap 'rm -f "$BASE_ROWS" "$SEEN_ROWS"' EXIT
if [[ -n "$BASELINE" && -r "$BASELINE" ]]; then
  while read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    line="${line% TEMPORARY}"
    echo "$line" >> "$BASE_ROWS"
  done < "$BASELINE"
fi

SPEC_BASE="$(basename -- "$SPEC")"

NEW=()
KNOWN=()
INFO=()

# `add_on` is emitted LAST because it is the field that is routinely empty, and
# tab is IFS whitespace — bash collapses runs of it, so an empty field in the
# middle silently shifts every field after it. As the trailing field it just
# reads back as "".
while IFS=$'\t' read -r idx iface name addon; do
  [[ -z "${name:-}" ]] && continue
  if [[ ! "$name" =~ $NODE_ADMIN_RE && ! "$name" =~ $NODE_ADMIN_PREFIX_RE ]]; then
    continue
  fi
  if [[ -n "$addon" ]]; then
    INFO+=("$idx/$iface/$name|behind add_on \"$addon\" — opt-in, out of scope")
    continue
  fi
  key="$SPEC_BASE $idx $iface $name"
  echo "$key" >> "$SEEN_ROWS"   # everything actually exposed, for the stale check
  if grep -Fxq "$key" "$BASE_ROWS" 2>/dev/null; then
    KNOWN+=("$key")
  else
    NEW+=("$idx/$iface/$name")
  fi
done < <(jq -r '
  .proposal.specs[] as $s
  | $s.api_collections[]? as $c
  | $c.apis[]?
  | select(.enabled == true)
  | "\($s.index)\t\($c.collection_data.api_interface)\t\(.name // "")\t\($c.collection_data.add_on // "")"
' "$SPEC")

if [[ ${#INFO[@]} -gt 0 ]]; then
  echo "=== INFO (gated behind an add-on — the opt-in boundary doing its job) ==="
  printf '%s\n' "${INFO[@]}"
  echo
fi

if [[ ${#KNOWN[@]} -gt 0 ]]; then
  echo "=== KNOWN (on the baseline: pre-existing, ticketed, still wrong) ==="
  printf '%s\n' "${KNOWN[@]}"
  echo
fi

# A baseline row for a method that is no longer exposed is STALE, and a stale row
# is not harmless: it silently re-permits the exposure if the fix is ever
# reverted. So the ledger cleans itself — a stale row fails, and the fix is to
# delete it.
#
# The exception is a row tagged TEMPORARY, which exists precisely because it is
# expected to go stale (a fix in flight on another branch). Those report and do
# not fail, because the merge that makes them stale is usually someone else's and
# should not turn their CI red.
STALE=()
STALE_TEMP=()
while read -r line; do
  raw="${line%%#*}"
  raw="$(echo "$raw" | xargs || true)"
  [[ -z "$raw" ]] && continue
  temp=0
  if [[ "$raw" == *" TEMPORARY" ]]; then
    temp=1
    raw="${raw% TEMPORARY}"
  fi
  # Only rows about THIS spec can be judged from this invocation.
  [[ "$raw" == "$SPEC_BASE "* ]] || continue
  if ! grep -Fxq "$raw" "$SEEN_ROWS" 2>/dev/null; then
    if [[ $temp -eq 1 ]]; then STALE_TEMP+=("$raw"); else STALE+=("$raw"); fi
  fi
done < "${BASELINE:-/dev/null}"

if [[ ${#STALE_TEMP[@]} -gt 0 ]]; then
  echo "=== STALE, TEMPORARY (the in-flight fix landed — delete these rows now) ==="
  printf '%s\n' "${STALE_TEMP[@]}"
  echo
fi

if [[ ${#STALE[@]} -gt 0 ]]; then
  echo "=== STALE BASELINE ROWS ==="
  printf '%s\n' "${STALE[@]}"
  cat <<EOF

FAIL: ${#STALE[@]} baseline row(s) name a method that $SPEC_BASE no longer serves
enabled from a base collection. The exposure is fixed, so the row is dead weight
— and worse than dead: it would silently re-permit the method if the fix were
reverted. Delete these rows from $(basename -- "${BASELINE:-node_admin_baseline.txt}").
EOF
  exit 1
fi

echo "=== NEW NODE-ADMIN EXPOSURE ==="
if [[ ${#NEW[@]} -eq 0 ]]; then
  echo "(none)"
  echo
  echo "OK: $SPEC_BASE serves no new node-operator control from a base collection."
  exit 0
fi

printf '%s\n' "${NEW[@]}"
cat <<EOF

FAIL: $SPEC_BASE serves ${#NEW[@]} node-operator control(s) ENABLED from a base
collection (add_on ""). Every provider on this chain would offer them, importing
specs inherit them, and the effect lands on the provider's node — so the damage
is not scoped to the caller.

Resolve per method, and record the reasoning where the next reader will find it:

  disable  "enabled": false, plus a positive-evidence row in the PR body's
           disabled-API justifications table (check_disabled_count.sh asserts
           the count matches).
  gate     move it into a named add_on so a provider opts in rather than
           serving it by default.
  baseline if it is pre-existing and being fixed under its own ticket, add the
           row to $(basename -- "${BASELINE:-node_admin_baseline.txt}") WITH that ticket. A
           baseline row is a debt record, not an exemption.
EOF
exit 1
