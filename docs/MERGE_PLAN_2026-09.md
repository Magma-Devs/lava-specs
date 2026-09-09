# Merge plan for the inheritance-audit branches

Four independent branches plus a verified integration of them. **Order matters** —
one pair has a real dependency and one pair conflicts. Every figure below was
measured on the fully integrated tree, which is the state that will actually
ship.

There are two ways to land this. Pick one.

### Option A — four reviewable PRs, in this order

| order | branch | commits | files | why here |
|---|---|---|---|---|
| 1 | `fix/eth1-feehistory-block-parsing` | 1 | 4 | must precede #2 and the follow-up — both depend on ETH1 being correct |
| 2 | `fix/substrate-evm-eth1-inheritance` | 1 | 26 | the trust-repair deliverable |
| 3 | `fix/substrate-base-spec` | 2 | 41 | stacked on #2 |
| 4 | `fix/audit-flagged-imports` | 1 | 3 | independent |

Then cherry-pick the two follow-up commits from the integration branch —
`19e3723` (drop the redundant `eth_feeHistory` overrides + ledger lines) and
`6e31f54` (the real-merge verification harness and this plan). Neither is valid
before #1 and #2 are both in.

### Option B — one branch, already integrated and verified

`integration/inheritance-audit` **is** all four merged in the order above, with
both conflicts resolved and the two follow-up commits on top: 8 commits, 62
files. This is the tree every result in this document was measured on. Merging
it lands everything at once and skips the per-PR review granularity.

## Two conflicts, both already resolved and verified

These are already resolved on `integration/inheritance-audit`; they matter only
for Option A.

**`moonbeam.json` / `peaq.json` between #1 and #2.** Both delete
`eth_createAccessList` — #1 because it became a stale override once ETH1 was
fixed, #2 because it was byte-identical dead weight. Take #2's side (the
superset); it also deletes `eth_getProof`, `eth_sign`, `eth_signTransaction`.

**`hyperliquid.json` between #1 and #4** auto-merges cleanly (#1 edits
`eth_feeHistory`, #4 appends `eth_sendRawTransaction`).

## Why the follow-up cannot merge earlier

TRAC, HYDRATION, BITTENSOR and LIT carry an `eth_feeHistory` override. Before #1,
that override is the *correct* value and ETH1's is wrong — deleting it would be a
regression. After #1, the override differs from ETH1 only in `compute_units`
(20 vs 10, with no evidence for 20) and in BITTENSOR's case
`category.deterministic`. The follow-up commit deletes all four so they inherit, and drops the four
now-obsolete `REDUNDANT` lines from `spec-inheritance-exceptions.txt`.

## Before opening any of these: two CI hazards

### 1. `spec_pipeline.yml` will auto-start on every one of them

```yaml
on:
  pull_request:
    types: [opened]
    paths:
      - "*.json"
```

All five touch root spec JSONs, so all five auto-start the pipeline — **which
commits its Phase 10 fixes to the branch**. That is how PR #80 silently drifted a
mainnet block, and how PR #130's fixer introduced 13 disables the body had
already declared as zero.

For #3 in particular this is destructive: its whole claim is that it is a **pure
refactor**, verified at 45,933 definitions. A fix pass landing on it voids that
property and no reviewer can re-derive it from the diff.

**Do one of:** open these with the pipeline disabled, or re-run the
before/after resolved-closure comparison after any pipeline commit and revert
anything it touched.

### 2. Each PR body needs its `<!-- disabled-count: N -->` marker

`check_disabled_count.sh` compares the file's `enabled: false` set against the
body, and the guard job in `spec_guards.yml` runs it on every spec PR. The
disables in #2 and #4 **are** the correctness fix — each one is backed by a live
`-32601`. Without the marker the guard cannot verify them and the Phase 10 fixer
has no ledger to respect.

Counts, read from the files on the merged tree:

| PR | file | `<!-- disabled-count: N -->` | what the disables are |
|---|---|---|---|
| #2 | `trac.json` | 7 | ETH1 methods NeuroWeb answers `-32601` for |
| #2 | `hydration.json` | 20 | 7 new + 13 pre-existing Substrate admin methods |
| #2 | `bittensor.json` | 8 | 7 + `eth_sendTransaction`, also `-32601` |
| #2 | `lit.json` | 7 | same 7 |
| #4 | `tron.json` | 5 | 4 new + `eth_sendRawTransaction`, already disabled |
| #1,#3,#4 | `hyperliquid.json`, `substrate.json`, `moonbeam.json`, `peaq.json` | 0 | no disables |

Under Option B the same counts apply; the body carries one marker per changed
spec file.

The seven common to #2 are `eth_compileLLL`, `eth_createAccessList`,
`eth_getCompilers`, `eth_getProof`, `eth_sign`, `eth_signTransaction`,
`rpc_modules` — each probed on the chain's live endpoint. The evidence tables
are in `docs/SPEC_INHERITANCE_AUDIT_2026-09.md` and
`docs/FLAGGED_IMPORTS_AUDIT_2026-09.md`; paste the relevant one into each body so
the fixer and the reviewer see the same ledger.

## What the merged tree was verified against

Everything above was measured on `integration/inheritance-audit`:

| check | result |
|---|---|
| `check_parent_duplication.sh` over all 141 files | **only CANTO and VECHAIN fail** — the two blocked specs, deliberately unledgered |
| 15 guard self-tests | all pass |
| catalog through the real chain merge (`scripts/specmergecheck/`) | `loaded 271 indices from 141 files, expanded 271 indices, 0 failed` |
| SUBSTRATE refactor, before vs after, through the real merge | `46332 definitions across 269 indices, 0 changed` |

## After the last merge

Re-run the two checks that back these claims:

```bash
# 1. the guard, across the whole catalog
for f in *.json; do bash .claude/skills/create-spec/scripts/check_parent_duplication.sh "$f"; done

# 2. the guard's own suite
for t in .claude/skills/create-spec/scripts/test_*.sh; do bash "$t"; done
```

Expected: **5 UNIMPORTED findings and nothing else** — CANTO and VECHAIN (both
blocked on unreachable endpoints, deliberately unledgered so they keep failing)
and HYPERLIQUID, TRX, THORCHAIN (audited, ledgered, so they pass once #4 and the
follow-up are in). All 15 guard self-tests pass.

## Still open after all five

1. **The Substrate `block_parsing` correctness pass.** `substrate.json` holds
   majority values, not verified ones — ~47 methods where specs disagree between
   `PARSE_BY_ARG ["N"]` and `DEFAULT ["latest"]`, and for each exactly one is
   right. Every child keeps an override, so nothing resolves to an unverified
   base value today. Same defect class as the `eth_feeHistory` bug #1 fixes.
2. **CANTO and VECHAIN** — no reachable endpoint from this environment. CANTO is
   29/30 byte-identical with ETHERMINT and needs only its 8 `virtual_frontier_*`
   methods probed. VECHAIN needs the full 54-method ETH1 probe.
3. **Stale `addons: ["evm"]` legs in deployed router configs** for TRAC,
   HYDRATION, BITTENSOR and LIT. Harmless after #2 — the router logs *"ignoring
   standalone-addons: url declares no add-on collection"* and falls back to the
   base collection — but dead config. Not doable from this repo; it holds only
   `config/mantle.yml`.
