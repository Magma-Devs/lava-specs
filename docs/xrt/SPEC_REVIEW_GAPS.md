# Spec Review — `xrt.json` (Robonomics / XRT)

Standalone `/review-spec` pass, run because PR #128's pipeline truncated after Phase 8 three times
and never produced Phase 9/11 review coverage. This substitutes for that review; it does **not**
substitute for the fix pass or the Phase 10b smoke re-boot.

- Spec: `xrt.json` — 1 spec entry (`XRT`), 1 collection (`jsonrpc`, `add_on: ""`), 115 APIs, no `imports`
- Live endpoint used: `https://kusama.rpc.robonomics.network` (the only reachable Robonomics host)
- Reference specs for comparison: `kusama.json`, `polkadot.json` (both merged on `main`)

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| MEDIUM | 2 |
| MINOR | 3 |

**Verdict: ready to merge once the two MEDIUMs are applied.** Both are mechanical, both are deviations
from an already-merged sibling spec, and neither requires new research.

---

## CRITICAL — none

---

## MEDIUM-1 — Eight `_At` methods parse the block from an optional argument

Every `_At`-suffixed method uses `PARSE_BY_ARG` on a trailing block-hash parameter that is **optional**,
where both sibling relay-chain specs use `DEFAULT` / `["latest"]`.

| Method | `xrt.json` | `kusama.json` |
|---|---|---|
| `childstate_getKeysPagedAt` | `PARSE_BY_ARG ["3"]` | `DEFAULT ["latest"]` |
| `state_callAt` | `PARSE_BY_ARG ["2"]` | `DEFAULT ["latest"]` |
| `state_getKeysPagedAt` | `PARSE_BY_ARG ["3"]` | `DEFAULT ["latest"]` |
| `state_getStorageAt` | `PARSE_BY_ARG ["1"]` | `DEFAULT ["latest"]` |
| `state_getStorageHashAt` | `PARSE_BY_ARG ["1"]` | `DEFAULT ["latest"]` |
| `state_getStorageSizeAt` | `PARSE_BY_ARG ["1"]` | `DEFAULT ["latest"]` |
| `state_queryStorageAt` | `PARSE_BY_ARG ["1"]` | `DEFAULT ["latest"]` |
| `system_dryRunAt` | `PARSE_BY_ARG ["1"]` | `DEFAULT ["latest"]` |

**Live evidence.** `state_getStorageAt` called with only its storage-key argument — the trailing block
hash omitted — returns a normal response with **no error**, confirming the argument is optional.

**Impact.** When a client omits the optional trailing argument (a valid, working call pattern), the
router reads a parameter that is not present in `params[]`, producing wrong or failed block attribution
and degrading data reliability.

**Fix.** Set `block_parsing` to `{"parser_arg": ["latest"], "parser_func": "DEFAULT"}` on all eight,
matching `kusama.json` and `polkadot.json`.

**Precedent.** This is the identical finding raised by the Phase 11 reviewer on Enjin Relaychain
(PR #130) and fixed there in commit `4bef84c`.

---

## MEDIUM-2 — `submitAndWatch` methods marked `stateful: 0` while broadcasting signed extrinsics

`author_submitAndWatchExtrinsic` and `transactionWatch_v1_submitAndWatch` carry `stateful: 0`, yet both
submit a real signed extrinsic to the network. Their non-watching twins in the same collection are
classified correctly:

| Method | stateful | hanging_api | timeout_ms |
|---|---|---|---|
| `author_submitExtrinsic` | **1** | true | 15000 |
| `transaction_v1_broadcast` | **1** | true | 15000 |
| `author_submitAndWatchExtrinsic` | **0** | false | none |
| `transactionWatch_v1_submitAndWatch` | **0** | false | none |

**The catalog is inconsistent here, and that is worth stating plainly:** `polkadot.json` marks both
methods `stateful: 1`; `kusama.json` marks both `stateful: 0`. `xrt.json` follows Kusama.

**Recommendation: set both to `stateful: 1`.** They broadcast state-changing transactions, that is what
the flag means, and it is the direction the catalog is moving — the same two methods were changed from
`0` to `1` on Enjin Relaychain (PR #130) during its Phase 10 fix pass. Leaving them at `0` means the
pipeline will *probe* them rather than skipping them, and a probe of a broadcast method is exactly what
`stateful` exists to prevent.

---

## MINOR

1. **No testnet entry.** `xrt.json` declares only `XRT`. This is correct — no live public Robonomics
   testnet endpoint was found — and it is the honest outcome (a testnet entry with no live endpoint and
   no chain-id of its own inherits the mainnet identity and cannot route). Recorded so the absence is
   not mistaken for an omission.
2. **Single upstream.** Only one reachable host, `kusama.rpc.robonomics.network`. Phase 8 recorded
   `SINGLE_UPSTREAM`; the 12 `TIMEOUT` rows and 17 `FAIL` rows in that probe are consistent with one
   un-rotated endpoint absorbing 115 sequential probes, and should **not** be read as method absences.
   Per the free-tier rule, none of them justifies disabling anything.
3. **No API documentation supplied**, so no docs-versus-spec diff was possible. Mitigated far better
   than usual — see the completeness check below.

---

## What was verified and found correct

- **Method coverage is exact.** The live node's own `rpc_methods` returns **115** methods; the spec
  declares **115**. Set comparison: **zero missing, zero extra**. This is stronger evidence than a docs
  diff would have been.
- **chain-id verification matches live.** Spec `expected_value`
  `0x631ccc82a078481584041656af292834e1ae6daab61d2875b4dd0c14bb9b17bc` is byte-for-byte the genesis hash
  returned by `chain_getBlockHash[0]`.
- **The `pruning` verification is real and correctly calibrated.** Its directive queries
  `state_getRuntimeVersion` at hardcoded block `0x30df93e8…87d5`; the live node returns
  `specVersion: 5`, matching `expected_value: "5"`.
- **`GET_EARLIEST_BLOCK` and `pruning` follow the house Substrate pattern.** Both are byte-identical in
  shape to `kusama.json` — including `GET_EARLIEST_BLOCK` returning the genesis hash rather than an
  earliest-block number, and `pruning` carrying only an archive-tier value with no `latest_distance`.
  Odd in isolation, but flagging it here would be inconsistent with a merged sibling. **Not a defect in
  this spec**; if the pattern is wrong it is wrong catalog-wide and belongs in its own ticket.
- **Network parameters pass every formula.** `average_block_time` 6000, `block_distance_for_finalized_data`
  2, `blocks_in_finalization_proof` 1 (fast finality — correct for a GRANDPA parachain),
  `allowed_block_lag_for_qos_sync` 2 = `ceil(10000/6000)`. `check_network_params.sh` reports no failures.
  Phase 8 measured 6238ms empirically — **+3.97%**, well inside the 20% tolerance.
- **Removed-field guard passes** — none of the 15 fields dropped in smart-router#218 are present; the
  envelope is the canonical `{ "proposal": { "specs": [ … ] } }`.
- **No `hanging_api: true` without `timeout_ms`** — the check no validator covers. Clean.
- **`stateful: 1` direction spot-checked** — all ten flagged methods are genuinely state-changing
  (`author_insertKey`, `author_rotateKeys`, `author_submitExtrinsic`, `offchain_localStorageSet`/`Clear`,
  `system_addLogFilter`/`addReservedPeer`/`removeReservedPeer`/`resetLogFilter`, `transaction_v1_broadcast`).
- **Compute units are sane and sibling-aligned.** 68 methods at 10 CU, 28 at 20, 6 at 40, 1 at 100,
  12 at 1000. All twelve 1000-CU methods are named by a `SUBSCRIBE` directive; every unsubscribe is 10 CU,
  matching both the mechanical rule and `kusama.json`.
- **Archive extension identical to `kusama.json`** — `cu_multiplier: 5`, `rule.block: 127`.
- **Parse directives complete** — `GET_BLOCKNUM` (`chain_getHeader` → `["0","number"]`, hex),
  `GET_BLOCK_BY_NUM` (`chain_getBlockHash[%d]`), `GET_EARLIEST_BLOCK`, plus 12 `SUBSCRIBE` / 13
  `UNSUBSCRIBE` pairs. The archive ↔ pruning ↔ `GET_EARLIEST_BLOCK` triplet is complete.

## Scope limits of this review

- Phases 9 and 11 of the pipeline run **three independent reviewers plus a fourth in clean context**.
  This is one pass. It is better than nothing and worse than the pipeline.
- No fix pass and no Phase 10b smoke re-boot were run. If the two MEDIUMs are applied, the spec should
  be re-booted against the router before merge.
- Per-API block parsing beyond the eight `_At` methods was reviewed by inspection against sibling specs,
  not exercised against production traffic.
