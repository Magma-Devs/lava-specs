# Phase 1: Research & Planning

## Step 1.1: Blockchain Analysis
**Objective**: Understand the blockchain's technical characteristics

**Tasks**:
- [ ] Research the blockchain's consensus mechanism (PoW, PoS, BFT, etc.)
- [ ] Identify the average block time (test on mainnet/testnet)
- [ ] Determine block finality rules (probabilistic vs deterministic)
- [ ] Document the RPC protocol(s) used (JSON-RPC, REST, gRPC, WebSocket)
- [ ] Find official RPC documentation
- [ ] Identify if the chain is EVM-compatible (consider inheritance from ETH1)

**Example Findings**:
```
Blockchain: Polygon
Block Time: ~2 seconds (2000ms)
Finality: Fast finality (1 block distance)
Protocol: JSON-RPC (EVM-compatible)
Inheritance: ETH1 ✓
```

## Step 1.1a: Third-Party API Provider Assessment
**Objective**: Determine whether the spec wraps a native node RPC or a third-party API provider

Some blockchains are accessed through third-party API providers (e.g., Blockfrost for Cardano) rather than directly through the node's native RPC. This is a foundational decision that affects every aspect of the spec.

**Decision Tree**:
- Does the chain have a widely-used native RPC? → Use native RPC
- Is the chain only practically accessible through a third-party API? → Wrap the third-party API
- Does the third-party API aggregate or transform chain data? → Evaluate carefully

**If Wrapping a Third-Party API Provider**:

1. **Identify the API provider** and document it (e.g., Blockfrost, Alchemy, QuickNode)
2. **Use `api_interface: "rest"`** — most third-party APIs use REST, not JSON-RPC
3. **Authentication**: The provider likely requires an API key/token. Use the `pass_send` header kind to forward client-provided credentials:
```json
{
  "headers": [
    {"name": "project_id", "kind": "pass_send"}
  ]
}
```
4. **Exclude platform-specific endpoints** that are not chain data:
   - Health/status endpoints (`/health`, `/health/clock`) — these report the API provider's status, not chain state
   - Usage metrics (`/metrics`, `/metrics/endpoints`) — account-specific billing data
   - IPFS or storage endpoints — hosted on a different server/domain
   - Admin endpoints — provider management, not chain queries
5. **Exclude deprecated endpoints** — if the API docs mark an endpoint as `deprecated: true`, exclude it from the spec. Use the non-deprecated replacement instead (e.g., `/addresses/{address}/transactions` instead of deprecated `/addresses/{address}/txs`)
6. **Network variants** — third-party providers often use different base URLs per network (mainnet, testnet). The spec itself doesn't encode base URLs; instead, providers configure their endpoints. Use `imports` so testnets inherit the mainnet spec and only override verifications (chain-id).

**Example: Cardano with Blockfrost**
```
API Provider: Blockfrost (https://blockfrost.io)
Protocol: REST
Authentication: project_id header (pass_send)
Excluded: /health, /health/clock, /metrics, /metrics/endpoints, /ipfs/* (different server)
Excluded (deprecated): /addresses/{address}/txs, /assets/{asset}/txs
```

## Step 1.2: API Discovery
**Objective**: Catalog all available RPC methods

**Tasks**:
- [ ] Set up a test node or use a public RPC endpoint
- [ ] List all available RPC methods (use documentation + testing)
- [ ] Categorize APIs by function:
  - Block queries (getBlock, getBlockNumber, etc.)
  - Transaction queries (getTransaction, getTransactionReceipt, etc.)
  - State queries (getBalance, getCode, call, etc.)
  - Transaction submission (sendTransaction, sendRawTransaction, etc.)
  - Subscriptions (subscribe, unsubscribe, etc.)
  - Network info (chainId, version, peerCount, etc.)
  - Special/chain-specific methods
- [ ] Test each API to understand its parameters and responses
- [ ] Identify which APIs are standard vs chain-specific

**Documentation Template**:
```markdown
# API Inventory for [CHAIN_NAME]

## Standard APIs (from inheritance)
- eth_blockNumber
- eth_getBlockByNumber
- ...

## Chain-Specific APIs
- custom_method_1: Description
- custom_method_2: Description
```

## Step 1.3: Spec Index Assignment
**Objective**: Choose a unique spec identifier

**Tasks**:
- [ ] Review existing specs in `mainnet-1/specs/`, `testnet-1/specs/`, `testnet-2/specs/`
- [ ] Choose a unique, short index (3-10 characters, uppercase)
- [ ] Follow naming conventions:
  - Mainnet: `CHAINNAME` (e.g., `ETH1`, `POLYGON`, `STRK`)
  - Testnet: `CHAINNAMET` or `CHAINNAMES` (e.g., `SEP1`, `POLYGONA`, `STRKS`)
- [ ] Document both mainnet and testnet indices

**Example**:
```
Mainnet: MYCHAIN
Testnet: MYCHAINT
```
END-OF-PHASE1-SENTINEL
