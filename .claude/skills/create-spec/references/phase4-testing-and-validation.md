# Phase 4: Testing & Validation

## Step 4.1: Syntax Validation
**Objective**: Ensure JSON is valid and properly formatted

**Tasks**:
- [ ] Validate JSON syntax (use `jq` or online validator)
```bash
jq . mychain.json
```
- [ ] Check all required fields are present
- [ ] Verify no duplicate API names within same collection
- [ ] Ensure all `parser_arg` arrays are valid
- [ ] Confirm all boolean values are lowercase (true/false)

## Step 4.2: API Testing
**Objective**: Verify each API works as configured

**Test Each API**:
1. **Manual RPC Testing**:
```bash
# Example: Test eth_blockNumber
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  https://your-rpc-endpoint
```

2. **Test Block Parsing**:
   - [ ] For each API, verify the block parameter is at the specified position
   - [ ] Test with different block references (latest, earliest, specific number)
   - [ ] Confirm responses include expected block information

3. **Test Parse Directives**:
   - [ ] Verify GET_BLOCKNUM returns current block number
   - [ ] Verify GET_BLOCK_BY_NUM returns block hash correctly
   - [ ] Verify GET_EARLIEST_BLOCK works for pruning detection
   - [ ] Runtime confirmation: after the Phase 8 router boot, check `curl -s http://localhost:7779/metrics` — `lava_rpcsmartrouter_latest_block` > 0 proves the router parsed `GET_BLOCKNUM` through this spec (see smart-router-tester Step 3.5)

4. **Test Verifications**:
   - [ ] Run chain-id verification against mainnet and testnet
   - [ ] Confirm returned value matches expected_value
   - [ ] Test any additional verifications

## Step 4.3: Data Reliability Testing
**Objective**: Verify deterministic APIs return consistent results

**Tasks**:
- [ ] Identify all APIs marked as deterministic
- [ ] For each deterministic API:
  1. Call with same block parameter multiple times
  2. Verify identical responses
  3. Confirm deterministic flag is appropriate
- [ ] Verify non-deterministic APIs that vary between calls are flagged correctly

## Step 4.4: Compute Units Validation
**Objective**: Ensure CU assignments are reasonable and consistent with established specs

**1. Cross-Reference with ETH1 / TENDERMINT**:
- Compare similar APIs (block queries, tx submission, state reads) to `ethereum.json` and `tendermint.json`
- Transaction submission (sendRawTransaction, broadcast_tx) = 10 CU in both
- Block/state queries = 20 CU in ETH1; avoid over-pricing unless operation is demonstrably heavier

**2. Benchmark Process** (when no direct equivalent exists):
- Run each API 100 times
- Record average response time
- Note any slow outliers

**3. Response Time → CU Mapping**:
- <10ms operations: 10 CU
- 10-50ms operations: 20 CU
- 50-200ms operations: 60-100 CU
- >200ms operations: 100-1000 CU
- Full-chain scans (UTXO, txpool): 500-5000 CU + `timeout_ms` for long-running ops

**4. Test Under Load**:
- [ ] Simulate concurrent requests
- [ ] Identify if any APIs cause resource spikes
- [ ] Adjust CU values if needed

## Step 4.5: WebSocket / Subscription Testing
**Objective**: Validate that subscription-based methods (`eth_subscribe`, `eth_unsubscribe`) work end-to-end over WebSocket — *not just over HTTP, where they correctly fail with -32601*.

> ⚠️ **Router config requirement, easy to miss.** If the spec inherits `eth_subscribe` from ETH1 (or otherwise enables it), the **`direct-rpc` block's `node-urls` must include a `wss://` entry**, not just `https://`. Without it, the router serves regular HTTP requests fine, but subscriptions fail upstream with:
>
> ```
> ERR no chain proxy supporting requested extensions and internal path
>     extensions=websocket internalPath=
> ```
>
> The protocol is auto-detected from the URL scheme — just add the wss URL alongside the https URL in the smart-router config:
>
> ```yaml
> direct-rpc:
>   - name: <chain>-upstream-1
>     chain-id: <CHAIN>
>     api-interface: jsonrpc
>     node-urls:
>       - url: https://<chain-rpc>
>       - url: wss://<chain-rpc>     # required for eth_subscribe to reach upstream
> ```

**Tasks** (run against `ws://localhost:3360`):
- [ ] Open a WebSocket connection — verify the upgrade succeeds (`101 Switching Protocols`)
- [ ] Send a regular request (`eth_chainId`) over WS — verify normal request/response works
- [ ] Send `eth_subscribe` with a **valid subscription type** (e.g. `["newHeads"]`, `["logs", {...}]`) — Monad and most EVM chains reject `params:[]` with `Invalid params`. Common valid types per chain: `newHeads`, `logs`. Note: some chains (e.g. Monad) explicitly do NOT support `syncing` or `newPendingTransactions` channels.
- [ ] Verify subscription notifications arrive (e.g. wait one block for `newHeads`)
- [ ] Send `eth_unsubscribe` with the returned subscription id — verify cleanup
- [ ] Send a **disabled** method over WS (e.g. `eth_accounts` if disabled) — verify Lava's `api not supported` codepath fires the same as for HTTP

If WS request/response works but subscriptions fail with `no chain proxy supporting ... websocket`, the spec is fine — fix the router's `direct-rpc` `node-urls`.

END-OF-PHASE4-SENTINEL
