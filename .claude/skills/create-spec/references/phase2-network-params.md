# Phase 2: Network Parameters Configuration

## Step 2.1: Block Timing Parameters
**Objective**: Configure accurate timing and finality parameters

> ⚠️ **Anti-pattern: do not copy timing params from neighbor specs.**
> Neighbor specs (Sonic, Bera, Fantom, etc.) have *their* block times baked in. Even when the new chain "feels similar," `blocks_in_finalization_proof` and `allowed_block_lag_for_qos_sync` are derived from `average_block_time` via the formulas below — they are NOT free parameters to be eyeballed. Always:
> 1. Source `average_block_time` from the chain's official docs.
> 2. Apply the formulas below to derive the other two.
> 3. Show the calculation in your response so the user can verify it.
> Use neighbor specs only as a sanity check on the result, not as a source of values.

**Calculate and Set**:

1. **`average_block_time`** (in milliseconds)
   - Test on live network over 1000+ blocks
   - Use median or mean value
   - Examples: Ethereum=13000, Polygon=2000, StarkNet=30000

2. **`block_distance_for_finalized_data`**
   - Probabilistic finality (PoW/PoS): 6-12 blocks (e.g., Ethereum=8)
   - Fast finality (BFT): 1-3 blocks (e.g., Polygon=1)
   - Instant finality: 1 block

3. **`blocks_in_finalization_proof`** — finality-typed (NOT a single formula; see SKILL.md)
   - `1` — fast/instant finality: BFT, Tendermint/Cosmos, Solana, instant-settlement L2s (e.g. Akash=1, Algorand=1)
   - `3` — probabilistic finality: PoW / slow PoS (e.g. Ethereum=3, Polygon=3, StarkNet=3)
   - Fallback (only when the finality model can't be confidently classified): `max(ceil(1000 / average_block_time), 3)` — floors at 3, never falls back to 1
   - The gate (`check_network_params.sh`) accepts any of `{1, 3, fallback}`; it cannot infer the finality class, so it does not pin one value.

   > ⚠️ **Do not copy this value from a UTXO neighbour — several shipped with `1`
   > by inheritance, not by decision (MAG-3638).** `btc.json`, `bch.json`,
   > `doge.json` and `litecoin.json` all arrived in the initial import commit
   > carrying `blocks_in_finalization_proof: 1`, and upstream `lavanet/lava`
   > carries the same values *including the same self-contradiction* — `BTC=1`
   > while its own `BTCT=3`, identical block time, identical finality. A
   > deliberate convention does not contradict itself inside one file, so this
   > was inherited drift. All of them are now `3`.
   >
   > **The thing to actually check is the consensus mechanism, not the family.**
   > "UTXO" and "PoW" are not the question — *can the chain reorg away from a
   > recent block?* Two chains in this family answer differently:
   >
   > | chain | finality | value |
   > |---|---|---|
   > | BTC, BCH, DOGE, LTC | Nakamoto PoW — probabilistic, always reorgable | `3` |
   > | **DASH** | PoW **+ ChainLocks**: LLMQ masternode quorums sign the first-seen block, so a confirmed block cannot be reorged | **`1` — correct, deliberately left alone** |
   >
   > Dash is the case that proves the rule is about the mechanism. It looks like
   > a Bitcoin fork and fails a family-shaped sweep, but ChainLocks give it real
   > near-instant finality, so `1` is right for it and changing it would be the
   > actual error.

4. **`allowed_block_lag_for_qos_sync`**
   - Formula: `max(ceil(10000 / average_block_time), 1)` — i.e. tolerate ~10 seconds of block-lag
   - Examples: Polygon=5 (`ceil(10000/2000)=5`), Cosmos Hub=2 (`ceil(10000/6500)=2`), Ethereum=1 (`ceil(10000/13000)=ceil(0.77)=1`)
   - This is the verified convention (~64% of existing specs match it exactly, clustering at ~10s tolerance). A few slow-chain specs carry a hand-bumped value (e.g. ETH1's committed spec uses `2`); the formula value is the default — only deviate with a stated reason.

**Configuration Block**:
```json
{
  "average_block_time": 2000,
  "block_distance_for_finalized_data": 1,
  "blocks_in_finalization_proof": 3,
  "allowed_block_lag_for_qos_sync": 5
}
```

## Step 2.3: Chain Verification
**Objective**: Configure chain identity verification

> ⚠️ **Always source `chain-id` `expected_value` from a live RPC call, never from docs.** Documentation routinely contains typos (e.g. `0x27AF` written for decimal 10143, when the actual hex is `0x279F`). The node is canonical; the docs are not. If `expected_value` doesn't match what the upstream returns, the provider will fail to start with `verify failed expected and received are different`. For EVM chains, run:
> ```bash
> curl -s -X POST -H "Content-Type: application/json" \
>   -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
>   <PUBLIC_RPC_URL>
> ```
> Use the exact `result` string verbatim — do not re-derive from a decimal value yourself, as hex/decimal conversion errors are a common source of bugs.

**Tasks**:
1. **Get Chain ID**:
   - For EVM chains: Call `eth_chainId` or `net_version` against the **live RPC**, use the response verbatim
   - For Cosmos chains: Check genesis file
   - For other chains: Check documentation, then verify against live RPC

2. **Create Verification Object**:
```json
{
  "name": "chain-id",
  "parse_directive": {
    "function_template": "{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[],\"id\":1}",
    "function_tag": "VERIFICATION",
    "result_parsing": {
      "parser_arg": ["0"],
      "parser_func": "PARSE_BY_ARG",
      "encoding": "hex"
    },
    "api_name": "eth_chainId"
  },
  "values": [
    {
      "expected_value": "0x89"
    }
  ]
}
```

3. **Test Verification**:
   - [ ] Call the verification API against live node
   - [ ] Confirm expected_value matches actual response
   - [ ] Test on both mainnet and testnet
END-OF-PHASE2-SENTINEL
