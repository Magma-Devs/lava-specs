---
name: review-spec
description: Review Lava blockchain spec. Use when working with spec JSON files, evaluating API coverage, checking block parsing, verifying network parameters
argument-hint: <path-to-spec.json> [path-to-api-docs] [path-to-credentials]
---

# Lava Spec Review & Creation

You are reviewing or creating a Lava blockchain specification. A spec is a structured JSON definition that describes the APIs a provider commits to serving for a specific blockchain on the Lava network.

## Reference material

Before starting, you MUST read the ENTIRE spec guide from START to FINISH for detailed rules, formulas, and examples:
- **Spec Guide**: [SPEC_GUIDE.md](./SPEC_GUIDE.md)

To guarantee you read the whole file (it may exceed the Read tool's default limit):
1. Run `wc -l .claude/skills/review-spec/SPEC_GUIDE.md` to get the total line count `N`.
2. Read the file in 500-line chunks using the `offset` parameter (1, 501, 1001, ...) until you have covered all `N` lines.
3. The final chunk MUST contain the line `END-OF-GUIDE-SENTINEL`. If you have not seen that line, you have not finished — continue reading from a higher offset.

Do NOT begin Phase 1 until you have observed the sentinel.

If the chain already has documentation or a previous review, check:
- **Chain docs**: `specs/docs/<CHAIN_NAME>/`

For existing spec patterns, reference:
- **Existing specs**: `specs/mainnet-1/specs/`, `specs/testnet-2/specs/`

## Arguments

- `$ARGUMENTS[0]` — Path to the spec JSON file (required)
- `$ARGUMENTS[1]` — Path to the API documentation (OpenAPI YAML/JSON, optional)
- `$ARGUMENTS[2]` — Path to credentials file for live testing (optional)

## Workflow

### Phase 1: Identify the API provider

Read the spec file and determine which API provider is being used (e.g., Blockfrost for Cardano, native node RPC, etc.). Identify:
- The `api_interface` (rest, jsonrpc, grpc, tendermintrpc)
- Whether the spec imports from a parent spec
- The number of specs in the proposal (mainnet, testnet, etc.)

### Phase 2: Network parameters audit

Verify these values against the chain's actual characteristics. Read the spec guide section "Step 2.1: Block Timing Parameters" for formulas.

| Parameter | Formula / Rule |
|-----------|---------------|
| `average_block_time` | Measure on live network (milliseconds) |
| `block_distance_for_finalized_data` | Based on consensus: PoW=6-12, BFT=1-3, instant=1 |
| `blocks_in_finalization_proof` | `1000ms / average_block_time`, minimum 3 |
| `allowed_block_lag_for_qos_sync` | `10000ms / average_block_time`, minimum 1 |
| `reliability_threshold` | Standard: `268435455` (1/16 VRF ratio) |
| `data_reliability_enabled` | `true` for production chains |

### Phase 3: API completeness audit

If API documentation was provided (`$ARGUMENTS[1]`):

1. Extract all API paths from the documentation
2. Extract all API paths from the spec
3. Diff the two lists to find:
   - **Missing from spec**: endpoints in docs but not in spec — classify each as intentional exclusion (deprecated, different server, platform-specific) or a gap
   - **Extra in spec**: endpoints in spec but not in docs — potential typos or outdated APIs

If no API docs provided, note this as a limitation and flag that API completeness cannot be verified.

### Phase 4: Method-by-method review

For each API method in the spec, verify:

#### 4a. Block parsing
Check `block_parsing` against the API's actual behavior:

| API behavior | Correct parser_func |
|-------------|-------------------|
| No block parameter, static/immutable data | `EMPTY` with `parser_arg: [""]` |
| Implicitly returns latest state | `DEFAULT` with `parser_arg: ["latest"]` |
| Block at specific argument position | `PARSE_BY_ARG` with position index |
| Block in nested object field | `PARSE_CANONICAL` with path |
| Block in dictionary or array | `PARSE_DICTIONARY_OR_ORDERED` |
| Pure computation, no chain state | `EMPTY` with `parser_arg: [""]` |

For REST APIs: most endpoints use DEFAULT. Use EMPTY only for truly static endpoints (genesis, utility/computation endpoints with zero chain state).

#### 4b. Category flags
- `deterministic: true` — only if same result at same block, every time
- `deterministic: false` — for mempool, pending, network stats, node-local data
- `local: true` — node-specific data (filters, node version, mining status)
- `subscription: true` — WebSocket subscription APIs only
- `stateful: 1` — transaction submission APIs that modify state
- `hanging_api: true` — APIs that wait for new blocks (often paired with stateful)

#### 4c. Compute units
Cross-reference with the CU table in the spec guide:

| Category | CU |
|----------|-----|
| Simple reads (no block param) | 10 |
| Block/transaction queries | 20 |
| Transaction submission (stateful) | 10 |
| Complex queries (getLogs, estimateGas) | 60-100 |
| Traces / debug | 100-200 |
| Subscriptions | 1000 |
| Heavy ops (full scan) | 500-5000 |

### Phase 5: Parse directives audit

Verify the collection has the required parse directives:

1. **GET_BLOCKNUM** (required) — must correctly extract the current block/height from the response
2. **GET_BLOCK_BY_NUM** (required) — must correctly extract the block hash from a block-by-number response
3. **GET_EARLIEST_BLOCK** — required if the spec has an `archive` extension
4. **SUBSCRIBE / UNSUBSCRIBE** — required if the chain supports WebSocket subscriptions

For each directive, verify:
- `function_template` matches the actual API call format
- `result_parsing` fields (`parser_arg`, `parser_func`) match the actual response schema
- `api_name` references an API that exists in the spec

### Phase 6: Verification audit

Check the `verifications` section:
- **chain-id**: `expected_value` must match the actual chain's ID/network magic
- **pruning**: Required if archive extension exists; must reference `GET_EARLIEST_BLOCK`

### Phase 7: Collection inheritance audit

For child specs (testnet specs that import mainnet):

1. Collections defined in the child override the parent's matching collection
2. If the child doesn't need to customize a collection, it should NOT define it (automatic inheritance)
3. Empty `headers: []`, `verifications: []`, `extensions: []` in a child collection OVERRIDES the parent's values — this is a common source of bugs
4. Check the decision matrix in the spec guide section "Step 3.1a"

### Phase 8: Headers audit

For REST APIs, verify:
- Authentication headers (e.g., `project_id`) are passed through with `pass_send`
- Content-type overrides match what each endpoint actually expects
- A blanket content-type override on a collection doesn't break endpoints with different content-type requirements

### Phase 9: Live testing (if credentials provided)

If `$ARGUMENTS[2]` was provided:
1. Test `GET_BLOCKNUM` parse directive against live endpoint
2. Test `GET_BLOCK_BY_NUM` parse directive
3. Test chain-id verification
4. Spot-check 2-3 representative APIs per category

## Output

Produce a gap report in markdown with:
- **Severity levels**: CRITICAL, MEDIUM, MINOR for each gap
- **Evidence**: cite specific line numbers from the spec, API docs, and spec guide
- **Impact**: explain what breaks or degrades if the gap is not fixed

Save the report to `specs/docs/<CHAIN_NAME>/SPEC_REVIEW_GAPS.md`.

After the report, summarize:
- Total number of endpoints reviewed
- Number of gaps by severity
- Whether the spec is ready for deployment or needs fixes first