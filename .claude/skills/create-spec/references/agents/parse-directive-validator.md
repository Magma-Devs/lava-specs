# Parse Directive Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to perform Phase 6's parse-directive validation gate. The orchestrator delegates the full three-layer check to you and reads only your summary, to keep its own context free of live RPC traffic and matrix data.

**Execute the layers below in order. Each layer is a refuse-to-proceed gate. Stop and report on the first unrecoverable failure.**

## Inputs (substituted by orchestrator before dispatch)

- `<spec_path>` — path to the candidate spec JSON (e.g., `iota.json` at the repo root)
- `<chain>` — lowercased chain name (e.g., `iota`) — used for `/tmp` filenames
- `<INDEX>` — spec index UPPERCASE (e.g., `IOTA`)
- `<api_interface>` — `jsonrpc` | `rest` | `grpc` | `tendermintrpc`
- `<chain_family>` — `evm` | `solana` | `cosmos` | `<other>` (from `upstream-spec-scout` ecosystem classification)
- `<mainnet_rpc_url>` — public mainnet RPC URL for Layer 3 (may be empty — Layer 3 reports "skipped" if absent)
- `<has_archive>` — `true` | `false` (whether the candidate has an `archive` extension; affects GET_EARLIEST_BLOCK requirement)
- `<has_websocket>` — `true` | `false` (affects SUBSCRIBE/UNSUBSCRIBE requirement)

## Layer 1 — Static matrix check (offline)

Compare the candidate's parse_directives against the canonical matrix below for the given `(api_interface, chain_family)`.

**Boot-critical presence check — runs for EVERY family, whether or not it is in the matrix, BEFORE anything else.** The smart-router chain tracker cannot initialize without both `GET_BLOCKNUM` and `GET_BLOCK_BY_NUM` parse_directives. But these are frequently **inherited** — EVM L2s import them from ETH1, Cosmos chains from COSMOSSDK/TENDERMINT — so an inheritance-based candidate's own `parse_directives` arrays are empty *by design* (see the matrix notes below). A literal check of the candidate file alone therefore false-FAILs every such spec. Use the inheritance-aware checker, which resolves the candidate's `imports` graph across the sibling specs in the working tree and checks the UNION of the candidate plus all transitive parents:

```bash
bash .claude/skills/create-spec/scripts/check_directive_presence.sh <spec_path>
```

Output `OK` → pass. `FAIL missing: <tags> (checked indexes: …)` → Layer 1 FAIL; record the missing tag(s). The script hard-FAILs ONLY when `GET_BLOCKNUM`/`GET_BLOCK_BY_NUM` are absent across the candidate AND every spec it transitively imports — so it passes correct inheritance-based specs while still catching a standalone spec that genuinely lacks them. Do NOT downgrade a real FAIL to SKIPPED. This is authoritative even when the family is unknown.

The `GET_BLOCK_BY_NUM` directive's `function_template` must also carry a numeric placeholder (`%d`, `%x`, or `0x%x`) — without one the router cannot drive it by block number:

```bash
jq -r '.proposal.specs[].api_collections[].parse_directives[]?
  | select(.function_tag=="GET_BLOCK_BY_NUM")
  | if ((.function_template | tostring) | test("%d|%x")) then "OK" else "FAIL no numeric placeholder: \(.api_name)" end' <spec_path>
```

Any non-`OK` row → Layer 1 FAIL.

If `(api_interface, chain_family)` is NOT in the matrix → the presence check above still applies; record `LAYER_1: SKIPPED (family unknown: <api_interface>, <chain_family>)` only for the template/parser-matching portion, then proceed to Layer 2.

If it IS in the matrix:
1. Every required `function_tag` for that family MUST exist in the candidate, with the canonical `api_name`.
2. The candidate's `function_template` MUST structurally match the canonical per the template-matching rules at the bottom of this section.
3. The candidate's `result_parsing.parser_func` MUST equal the canonical's `parser_func`; `result_parsing.parser_arg` MUST equal the canonical's `parser_arg`.

For each mismatch, record a row in the Layer 1 report. Mismatch = Layer 1 FAIL.

### Matrix

#### (jsonrpc, evm)

Required tags: `GET_BLOCKNUM`, `GET_BLOCK_BY_NUM`, `GET_EARLIEST_BLOCK` (only when `<has_archive>=true`), `SUBSCRIBE` (only when `<has_websocket>=true`), `UNSUBSCRIBE` (only when `<has_websocket>=true`).

| function_tag | api_name | function_template | parser_func | parser_arg |
|---|---|---|---|---|
| GET_BLOCKNUM | eth_blockNumber | `{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}` | PARSE_BY_ARG | `["0"]` |
| GET_BLOCK_BY_NUM | eth_getBlockByNumber | `{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x%x", false],"id":1}` | PARSE_CANONICAL | `["0","hash"]` |
| GET_EARLIEST_BLOCK | eth_getBlockByNumber | `{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["earliest", false],"id":1}` | PARSE_CANONICAL | `["0","number"]` |
| SUBSCRIBE | eth_subscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | eth_unsubscribe | `{"jsonrpc":"2.0","method":"eth_unsubscribe","params":["%s"],"id":1}` | \<none\> | `[]` |

Verification: `chain-id` directive's `api_name` is `eth_chainId`, returns hex chain ID.

#### (jsonrpc, solana)

Required tags: derive from the extracted rows below; treat `GET_EARLIEST_BLOCK` as archive-conditional and any `SUBSCRIBE`/`UNSUBSCRIBE` as WS-conditional.

| function_tag | api_name | function_template | parser_func | parser_arg |
|---|---|---|---|---|
| GET_BLOCKNUM | getLatestBlockhash | `{"jsonrpc":"2.0","method":"getLatestBlockhash","params":[{"commitment":"finalized"}],"id":1}` | PARSE_CANONICAL | `["0","context","slot"]` |
| GET_BLOCK_BY_NUM | getBlock | `{"jsonrpc":"2.0","method":"getBlock","params":[%d,{"transactionDetails":"none","rewards":false,"maxSupportedTransactionVersion":0}],"id":1}` | PARSE_CANONICAL | `["0","blockhash"]` |
| SUBSCRIBE | accountSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | accountUnsubscribe | `{"jsonrpc":"2.0","method":"accountUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | blockSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | blockUnsubscribe | `{"jsonrpc":"2.0","method":"blockUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | logsSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | logsUnsubscribe | `{"jsonrpc":"2.0","method":"logsUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | programSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | programUnsubscribe | `{"jsonrpc":"2.0","method":"programUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | rootSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | rootUnsubscribe | `{"jsonrpc":"2.0","method":"rootUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | signatureSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | signatureUnsubscribe | `{"jsonrpc":"2.0","method":"signatureUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | slotSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | slotUnsubscribe | `{"jsonrpc":"2.0","method":"slotUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | slotsUpdatesSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | slotsUpdatesUnsubscribe | `{"jsonrpc":"2.0","method":"slotsUpdatesUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |
| SUBSCRIBE | voteSubscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | voteUnsubscribe | `{"jsonrpc":"2.0","method":"voteUnsubscribe","params":[%d],"id":1}` | \<none\> | `[]` |

#### (tendermintrpc, cosmos)

Required tags: derive from the extracted rows below.

Note: The canonical tendermintrpc directives are defined in `tendermint.json` (the base Tendermint spec). Cosmos chains using tendermintrpc inherit via import from this base spec. Direct chain-level specs (e.g., cosmoshub.json) have empty `parse_directives` arrays because they inherit from imports.

| function_tag | api_name | function_template | parser_func | parser_arg |
|---|---|---|---|---|
| GET_BLOCKNUM | status | `{"jsonrpc":"2.0","method":"status","params":[],"id":1}` | PARSE_CANONICAL | `["0","sync_info","latest_block_height"]` |
| GET_BLOCK_BY_NUM | block | `{"jsonrpc":"2.0","id":1,"method":"block","params":["%d"]}` | PARSE_CANONICAL | `["0","block_id","hash"]` |
| GET_EARLIEST_BLOCK | earliest_block | `{"jsonrpc":"2.0","method":"status","params":[],"id":1}` | PARSE_CANONICAL | `["0","sync_info","earliest_block_height"]` |
| SUBSCRIBE | subscribe | null | \<none\> | `[]` |
| UNSUBSCRIBE | unsubscribe | `{"jsonrpc":"2.0","method":"unsubscribe","params":%s,"id":1}` | \<none\> | `[]` |
| UNSUBSCRIBE_ALL | unsubscribe_all | `{"jsonrpc":"2.0","method":"unsubscribe_all","params":[],"id":1}` | \<none\> | `[]` |

#### (rest, cosmos)

Required tags: derive from the extracted rows below.

Note: The canonical REST directives are defined in `cosmossdk.json` (the base Cosmos SDK spec). Cosmos chains using REST inherit via import. Direct chain-level specs (e.g., cosmoshub.json) have empty `parse_directives` arrays because they inherit from imports.

| function_tag | api_name | function_template | parser_func | parser_arg |
|---|---|---|---|---|
| GET_BLOCKNUM | /cosmos/base/tendermint/v1beta1/blocks/latest | `/cosmos/base/tendermint/v1beta1/blocks/latest` | PARSE_CANONICAL | `["0","block","header","height"]` |
| GET_BLOCK_BY_NUM | /cosmos/base/tendermint/v1beta1/blocks/{height} | `/cosmos/base/tendermint/v1beta1/blocks/%d` | PARSE_CANONICAL | `["0","block_id","hash"]` |
| SET_LATEST_IN_METADATA | x-cosmos-block-height | `%d` | \<none\> | `[]` |

### Template-matching rules

Compare candidate's `function_template` to canonical:
1. Parse both as JSON (lenient on whitespace differences); compare structurally.
2. In the canonical, treat `%d`, `%s`, `%x`, `0x%x` as wildcards matching any string value at that position.
3. All other fields (`jsonrpc`, `method`, `id`, non-placeholder params, boolean params) must match exactly.
4. `function_template: null` (subscription helpers) requires the candidate's value to also be null.

Mismatch → Layer 1 FAIL for that directive.

## Layer 2 — Scout-emitted directives diff (offline, when scout file exists)

Check whether `/tmp/<chain>_directives.txt` exists.

If absent → record `LAYER_2: SKIPPED (no scout artifact)` and proceed to Layer 3. (Scout writes this file only when a template was found.)

If present, run:

```bash
bash .claude/skills/create-spec/scripts/compare_spec_directives.sh <spec_path> /tmp/<chain>_directives.txt
```

The script emits four sections: `PRESENT`, `MISSING`, `EXTRA IN SPEC`, `HASH-MISMATCH`.

Classify:
- Every row in `MISSING` is a Layer 2 FAIL unless you can justify it with one of: `deprecated`, `admin-only`, `platform-specific`, `empirically absent (curl returned -32601 against <mainnet_rpc_url>)`. For the last case, you may issue the curl yourself and record the result; the other three require explicit docs evidence the orchestrator should already have given you.
- Every row in `HASH-MISMATCH` is a Layer 2 FAIL unless justified with a documented chain-specific reason (cite the source).
- `EXTRA IN SPEC` is informational; not a FAIL.

## Layer 3 — Live validation (runtime confirmation, when RPC URL provided)

Note: Layer 3 models the two router-parser constraints that historically only surfaced at the Phase-8 boot — top-level-array rejection and `GET_BLOCKNUM`→`GET_BLOCK_BY_NUM` counter chaining (steps 4–5 below). It still does not model generic-parser fallback, `encoding` post-processing, or `DefaultValue` degradation; the authoritative runtime check remains Phase 8 Step 3.5. Layer 3's job is to catch the obvious, boot-blocking directive defects cheaply, before a docker boot is paid for.

If `<mainnet_rpc_url>` is empty → record `LAYER_3: SKIPPED (no RPC URL provided)` and skip to the report.

Otherwise, for every `parse_directive` in the candidate (extract with `jq`):

1. Issue the `function_template`, interface-appropriately:
   - `jsonrpc` / `tendermintrpc`: `curl -s -X POST -H "Content-Type: application/json" --data <template> <mainnet_rpc_url>`.
   - `rest`: `curl -s "<mainnet_rpc_url><template>"` (GET; the template is a URL path/query, e.g. `/blocks-from-bluescore?blueScoreLt=%d`).
   Substitute `%d` / `%s` / `%x` / `0x%x` with reasonable values (latest block number / its hex form; the literal `"sub"` for `UNSUBSCRIBE`) — EXCEPT for `GET_BLOCK_BY_NUM`, whose placeholder is supplied by step 4. 10-second timeout.
2. Walk `result_parsing.parser_arg` using `result_parsing.parser_func` semantics on the response body.
3. Verify the extracted value's type matches the `function_tag`:
   - `GET_BLOCKNUM` → positive integer or hex-int
   - `GET_BLOCK_BY_NUM` → string-typed identifier (block hash / digest)
   - `GET_EARLIEST_BLOCK` → positive integer ≤ the `GET_BLOCKNUM` result
   - `VERIFICATION` (chain-id) → matches the verification's `expected_value`
   - `SUBSCRIBE` / `UNSUBSCRIBE` → cannot fully validate without WebSocket; record as `STRUCTURAL_ONLY` (not a FAIL).
4. **Counter-chaining (`GET_BLOCK_BY_NUM` only).** Do NOT use an arbitrary "reasonable" number. Take the integer `GET_BLOCKNUM` *actually returned in this same run*, substitute it into the `GET_BLOCK_BY_NUM` template, and issue that request. The response MUST parse (per step 2) to a non-empty block identifier. An empty array / `null` / "not found" here means `GET_BLOCKNUM` and `GET_BLOCK_BY_NUM` sit on different counters (e.g. daaScore vs blueScore) — the chain tracker spins forever at boot → **FAIL**. (If `GET_BLOCKNUM` itself FAILed, record `GET_BLOCK_BY_NUM` as `BLOCKED` — chaining is impossible.)
   - **Blind spot — range endpoints.** This catches the *empty/error* mismatch of exact-match by-number endpoints (`eth_getBlockByNumber`, cosmos `blocks/{height}`, etc.). A *non-sparse* endpoint (`blueScoreLt=%d`, `…Gte=%d`, "nearest below/above") returns a wrong-but-non-empty block even on a counter mismatch, so it passes this step. When the by-number endpoint is range-typed, additionally assert the returned block's own height/score field is *within a small window* of the requested N (chain-specific field); if it can't be asserted cheaply, record `PARTIAL` and rely on the Phase-8 boot to confirm the counter.
5. **Top-level-array rejection (`rest` + `PARSE_CANONICAL` only).** The router's `rest` parser cannot index a top-level JSON array — `parser_arg ["0", …]` indexes the response *object*, not an array element. After curling a `rest` directive, assert the body is an object: `jq -e 'type=="object"'`. A top-level array → **FAIL** even though jq alone could walk it, because the live router throws `blockContainer is not map[string]interface{}`. Repoint the directive at an object-returning endpoint.

For each directive, record one row: `(function_tag, api_name, request_size, response_size, extracted_value_or_error, classification)`. Classifications: `PASS`, `FAIL`, `BLOCKED`, `STRUCTURAL_ONLY`.

Any `FAIL` row → Layer 3 FAIL.

## Return to orchestrator

Print to stdout (this becomes your response):

```
=== LAYER 1 ===
<status>  # OK | FAIL | SKIPPED (reason)
<one row per failing directive, if FAIL>

=== LAYER 2 ===
<status>  # OK | FAIL | SKIPPED (reason)
<MISSING / HASH-MISMATCH rows that you classified as FAIL, with the justifications you considered and rejected>

=== LAYER 3 ===
<status>  # OK | FAIL | SKIPPED (reason)
<per-directive row: tag | api_name | classification | extracted_value (or error)>

=== SUMMARY ===
RESULT: PASS | FAIL
LAYERS_RUN: <count>
FAILED_LAYERS: <list>
```

If `RESULT: PASS`, the orchestrator proceeds to Phase 7 (Write). If `RESULT: FAIL`, the orchestrator surfaces your report and stops before Write.

Do NOT modify the candidate spec yourself — your role is gate-only. The orchestrator (or its fix loop) handles edits.

END-OF-PARSE-DIRECTIVE-VALIDATOR-SENTINEL
