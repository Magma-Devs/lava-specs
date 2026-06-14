# Lava Specification Guide

## Table of Contents
1. [What is a Spec?](#what-is-a-spec)
2. [Purpose of Spec Methods and Configuration](#purpose-of-spec-methods-and-configuration)
3. [Importance in Lava Project](#importance-in-lava-project)
4. [Quality Evaluation Parameters](#quality-evaluation-parameters)
5. [Creating a New Chain Spec](#creating-a-new-chain-spec)
   - Phase 1: Research & Planning (incl. Third-Party API Provider Assessment)
   - Phase 3: API Configuration (incl. REST Block Parsing, Headers, Disabled/Deprecated APIs)
6. [Appendix](#appendix) (incl. Header Kinds Reference, REST vs JSON-RPC Quick Reference)

---

## What is a Spec?

A **specification (spec)** in Lava is a structured definition that describes the APIs a provider commits to providing to consumers for a specific blockchain network. It's essentially a contract that defines:

- **All supported API calls** for that blockchain (e.g., `eth_blockNumber`, `eth_getBalance`)
- **Compute Units (CU)** for each API call (reflecting the computational cost)
- **Block parsing rules** (how to extract block information from requests/responses)
- **Data reliability parameters** (finalization rules, verification methods)
- **Staking requirements** (minimum stake for providers and consumers)

Each spec has a unique **index** (e.g., `ETH1` for Ethereum, `STRK` for StarkNet, `POLYGON` for Polygon) and can **inherit from other specs** using imports (e.g., Polygon imports ETH1 since it supports Ethereum's JSON-RPC APIs).

---

## Purpose of Spec Methods and Configuration

The spec methods and configurations serve multiple critical purposes:

### API Definition & Classification

- **`name`**: Identifies each API method (e.g., `eth_call`, `starknet_getBlockWithTxs`)
- **`compute_units`**: Assigns computational cost (10-5000 CU depending on complexity)
- **`enabled`**: Controls whether the API is active
- **`api_interface`**: Specifies the protocol (jsonrpc, rest, grpc, tendermintrpc)
- **`type`**: GET or POST request type

### Block Parsing Configuration

- **`parser_func`**: Defines how to extract block numbers
  - `PARSE_BY_ARG`: Extract from specific argument position
  - `DEFAULT`: Use default "latest" block
  - `EMPTY`: No block parsing needed
  - `PARSE_CANONICAL`: Extract from nested object structure
  - `PARSE_DICTIONARY_OR_ORDERED`: Handle both dictionary and positional args
- **`parser_arg`**: Specifies which parameter contains the block reference
- Used for tracking which block data applies to and ensuring data reliability

### API Categorization

- **`deterministic`**: Whether the API returns the same result when called twice at the same block (enables data reliability checks)
- **`local`**: Marks node-local APIs that aren't relevant to other nodes
- **`subscription`**: Identifies WebSocket subscription APIs
- **`stateful`**: Marks transaction APIs that modify state
- **`hanging_api`**: APIs that wait for new blocks to be created

### Network-Specific Configuration

- **`average_block_time`**: Block time in milliseconds (e.g., 13000ms for Ethereum, 2000ms for Polygon)
- **`block_distance_for_finalized_data`**: Safety distance from latest block for finality (8 for Ethereum, 1 for Polygon)
- **`blocks_in_finalization_proof`**: Number of finalized blocks to keep for data reliability
- **`allowed_block_lag_for_qos_sync`**: QoS calculation for provider data freshness (formula: `10000ms / average_block_time` AND >= 1)

### Verification & Validation

- **`verifications`**: Defines checks providers must pass (e.g., chain-id verification, pruning checks)
- **`parse_directives`**: Templates for getting block numbers, block hashes, and subscription management
- **`extensions`**: Special capabilities like archive nodes with custom CU multipliers

### Add-ons & Extensions

- **`add_on`**: Groups related APIs (e.g., "debug", "trace", "bundler" for Ethereum)
- Allows providers to offer specialized services beyond base functionality
- **IMPORTANT:** Add-ons are inherited automatically when importing a spec (see Step 3.1a for detailed inheritance mechanics)
- Each unique `add_on` value creates a separate API collection that can be independently inherited or overridden

---

## Importance in Lava Project

Specs are **foundational** to Lava's architecture and serve as the backbone for:

### Provider-Consumer Contract
- Defines exactly what services providers must deliver
- Establishes clear expectations for API availability and behavior
- Enables trustless service delivery through verification mechanisms

### Economic Model
- Compute Units determine pricing and resource allocation
- Minimum stake requirements protect network quality
- Contributor percentages reward spec creators

### Data Reliability
- Deterministic APIs enable cross-provider verification
- Finalization rules ensure data integrity
- VRF-based reliability checks prevent fraud

### Network Scalability
- New blockchains can be added via governance proposals
- Specs can be updated to add new APIs
- Inheritance mechanism (`imports`) reduces duplication

### Quality of Service
- Block lag parameters ensure providers stay synchronized
- Verifications confirm providers are configured correctly
- Extensions enable specialized service tiers (e.g., archive nodes)

### Multi-Chain Support
- Currently supports 40+ blockchains (Ethereum, Polygon, StarkNet, Solana, Cosmos chains, etc.)
- Each network's unique characteristics are properly encoded
- Different versions of the same chain can coexist (mainnet vs testnets)

---

## Quality Evaluation Parameters

### Completeness Checklist
- [ ] **API Coverage**: Does it include all major APIs for the blockchain?
- [ ] **API Categorization**: Are all APIs properly marked (deterministic, local, subscription, stateful)?
- [ ] **Block Parsing**: Does every API have correct parsing configuration?
- [ ] **Compute Units**: Are CU values realistic for the computational cost?

### Accuracy Checklist
- [ ] **Network Parameters**: Are `average_block_time`, `block_distance_for_finalized_data`, and `blocks_in_finalization_proof` correct for the chain?
- [ ] **Verification Values**: Do chain-id and other verifications match the actual blockchain?
- [ ] **Parser Functions**: Are the right parser functions used for each API's structure?
- [ ] **Block References**: Are `parser_arg` values pointing to correct parameter positions?

### Data Reliability Checklist
- [ ] **Deterministic APIs**: Are read-only, repeatable APIs marked as deterministic?
- [ ] **Parse Directives**: Are `GET_BLOCKNUM`, `GET_BLOCK_BY_NUM`, and hash verification properly configured?
- [ ] **Finalization Rules**: Do finalization parameters match the blockchain's consensus mechanism?
- [ ] **Reliability Threshold**: Is VRF threshold set appropriately (typically 268435455 for 1/16 ratio)?

### Consistency Checklist
- [ ] **Inheritance**: If importing another spec, are only additional/override APIs defined?
- [ ] **Naming Conventions**: Do API names match the actual RPC method names?
- [ ] **API Collections**: Are APIs properly grouped by interface and add-on?
- [ ] **Multiple Versions**: If supporting multiple API versions, are they properly separated with `internal_path`?

### Performance Checklist
- [ ] **Compute Units**: Are CU values proportional to actual execution cost and aligned with ETH1/TENDERMINT for similar APIs?
- [ ] **Timeouts**: Do expensive APIs have appropriate `timeout_ms` values?
- [ ] **QoS Parameters**: Is `allowed_block_lag_for_qos_sync` set for optimal provider quality?
- [ ] **Extensions**: Are archive node multipliers reasonable (typically 5x)?

### Usability Checklist
- [ ] **Enabled Status**: Are deprecated/unsafe APIs properly disabled?
- [ ] **Add-ons**: Are specialized API groups (debug, trace) properly separated?
- [ ] **Subscription Support**: Are WebSocket APIs properly configured with SUBSCRIBE/UNSUBSCRIBE directives?
- [ ] **Documentation**: Does the spec proposal include clear title and description?

### Economic Viability Checklist
- [ ] **Min Stake**: Are provider/consumer stake requirements appropriate for the network's importance?
- [ ] **Contributor Percentage**: If specified, is the contributor reward reasonable?
- [ ] **Shares**: Is the shares value set correctly for network priority?

### Forward Compatibility Checklist
- [ ] **Multiple Versions**: Does the spec support multiple RPC versions where applicable?
- [ ] **Extension Mechanism**: Can the spec be extended without breaking existing functionality?
- [ ] **Import Chain**: If inheriting, does the inheritance chain make logical sense?

---

## Creating a New Chain Spec

This section provides a comprehensive step-by-step guide for creating a high-quality specification for a new blockchain.

### Phase 1: Research & Planning

#### Step 1.1: Blockchain Analysis
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

#### Step 1.1a: Third-Party API Provider Assessment
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

#### Step 1.2: API Discovery
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

#### Step 1.3: Spec Index Assignment
**Objective**: Choose a unique spec identifier

**Tasks**:
- [ ] Review existing specs at the repo root (all specs live flat as `<chain>.json`)
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

### Phase 2: Network Parameters Configuration

#### Step 2.1: Block Timing Parameters
**Objective**: Configure accurate timing and finality parameters

**Calculate and Set**:

1. **`average_block_time`** (in milliseconds)
   - Test on live network over 1000+ blocks
   - Use median or mean value
   - Examples: Ethereum=13000, Polygon=2000, StarkNet=30000

2. **`block_distance_for_finalized_data`**
   - Probabilistic finality (PoW/PoS): 6-12 blocks (e.g., Ethereum=8)
   - Fast finality (BFT): 1-3 blocks (e.g., Polygon=1)
   - Instant finality: 1 block

3. **`blocks_in_finalization_proof`**
   - Finality-typed: `3` for probabilistic finality (PoW / slow PoS); `1` for fast/instant finality (BFT, Tendermint/Cosmos, instant-settlement L2s — base.json and optimism.json use 1)
   - Fallback ONLY when the finality model can't be confidently classified: `max(ceil(1000ms / average_block_time), 3)`
   - Examples: Ethereum=3, Polygon=3, StarkNet=3, Base/Optimism=1 — do not flag `1` on a fast-finality chain

4. **`allowed_block_lag_for_qos_sync`**
   - Formula: `10000ms / average_block_time` AND >= 1
   - Examples: Ethereum=2 (10000/13000≈0.77→2), Polygon=5 (10000/2000=5)

5. **`reliability_threshold`**
   - Default: `268435455` (results in 1/16 VRF ratio)
   - Keep standard unless specific requirements

6. **`data_reliability_enabled`**
   - Set to `true` for production chains
   - Only disable for testing

**Configuration Block**:
```json
{
  "average_block_time": 2000,
  "block_distance_for_finalized_data": 1,
  "blocks_in_finalization_proof": 3,
  "allowed_block_lag_for_qos_sync": 5,
  "reliability_threshold": 268435455,
  "data_reliability_enabled": true
}
```

#### Step 2.2: Economic Parameters
**Objective**: Set appropriate staking and reward requirements

**Tasks**:
- [ ] **`min_stake_provider`**: Set minimum provider stake
  - Standard: `{"denom": "ulava", "amount": "5000000000"}` (5000 LAVA)
  - High-value chains: Consider higher stakes
  - Lower for testnets if appropriate

- [ ] **`min_stake_client`**: Set minimum consumer stake (if required)
  - Often omitted (not mandatory)
  - Use for high-demand chains

- [ ] **`shares`**: Set priority/weight
  - Standard: `1`
  - Higher values for premium chains (requires governance approval)

- [ ] **`contributor`**: Add if you're contributing the spec
  - Your Lava address
  - Only for original spec creators

- [ ] **`contributor_percentage`**: Set reward percentage
  - Typical: `"0.035"` (3.5%)
  - Requires governance approval

#### Step 2.3: Chain Verification
**Objective**: Configure chain identity verification

**Tasks**:
1. **Get Chain ID**:
   - For EVM chains: Call `eth_chainId` or `net_version`
   - For Cosmos chains: Check genesis file
   - For other chains: Check documentation

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

### Phase 3: API Configuration

#### Step 3.1: Determine Inheritance
**Objective**: Decide if the spec should inherit from existing specs

**Decision Tree**:
- EVM-compatible chain? → Consider inheriting from `ETH1`
- Cosmos SDK chain? → Consider inheriting from `COSMOSSDK` or specific version
- Specialized version of existing chain? → Inherit from parent

**If Inheriting**:
```json
{
  "index": "POLYGON",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [
        // Only chain-specific APIs here
      ]
    }
  ]
}
```

**If Not Inheriting**:
```json
{
  "index": "NEWCHAIN",
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [
        // All APIs must be defined here
      ]
    }
  ]
}
```

#### Step 3.1a: Understanding Collection Inheritance (CRITICAL)
**Objective**: Understand exactly how spec inheritance works at the collection level

This is one of the most important concepts for creating specs efficiently. Inheritance happens at the **API Collection** level, not just at the spec level.

##### How Collection Matching Works

Collections are matched by their `CollectionData`, which consists of:

```json
{
  "api_interface": "jsonrpc",  // Must match
  "internal_path": "",          // Must match
  "type": "POST",               // Must match
  "add_on": "debug"             // Must match - THIS IS KEY
}
```

Two collections are considered "the same" only if **ALL FOUR** fields match exactly. The `add_on` field is particularly important for understanding inheritance.

##### Two Inheritance Scenarios

**Scenario A: Automatic Inheritance (Collection NOT Defined in Child)**

When you import a spec (e.g., `"imports": ["ETH1"]`) but **DO NOT** define a matching collection in your child spec:

```json
{
  "index": "BASE",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""  // Only defining main collection
      },
      "apis": [/* chain-specific APIs */]
    }
    // NO debug collection defined
    // NO trace collection defined
  ]
}
```

**What happens:**
- ETH1's main collection (`add_on: ""`) is merged with your main collection
- ETH1's debug collection (`add_on: "debug"`) is **automatically appended entirely**
- ETH1's trace collection (`add_on: "trace"`) is **automatically appended entirely**
- ETH1's bundler collection is **automatically appended entirely**

**Result:** Your spec has ALL collections from ETH1 plus your custom APIs.

**Implementation:** This happens in `x/spec/types/spec.go` in the `CombineCollections` function. Collections from parent that don't have a matching `CollectionData` in the child are appended as-is.

**Scenario B: Override Inheritance (Collection Defined in Child)**

When you import a spec and **DO** define a matching collection:

```json
{
  "index": "EVMOS",
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "debug"  // EXPLICITLY DEFINING debug collection
      },
      "apis": [
        {
          "name": "debug_getRawBlock",
          "enabled": false  // Overriding to disable
        },
        {
          "name": "debug_traceTransaction",
          "compute_units": 150,  // Overriding CU
          "enabled": true
        }
      ],
      "verifications": [
        /* Custom verifications */
      ]
    }
  ]
}
```

**What happens:**
- ETH1's debug collection APIs are inherited
- Your explicitly defined APIs **override** the inherited ones (matched by `name`)
- APIs you don't mention are still inherited with ETH1's configuration
- Headers, parse directives, extensions, and verifications are **merged** (not overridden) — see below

**Result:** You have control over specific APIs while still inheriting most of the collection.

**Implementation:** This happens in `x/spec/types/api_collection.go` in the `InheritAllFields` and `CombineWithOthers` functions.

##### Non-API Field Merge Behavior (IMPORTANT)

All collection fields use **merge semantics**, not override semantics. This is implemented in `CombineUnique()` (`x/spec/types/combinable.go`). Each field type has a `Differeniator()` that determines how items are matched:

| Field | Merge? | Differentiator | Conflict Behavior |
|-------|--------|----------------|-------------------|
| **APIs** | Yes | `Name` | Child version wins |
| **Headers** | Yes | `Name` | Child version wins |
| **ParseDirectives** | Yes | `FunctionTag` (+ `ApiName` for SUBSCRIBE/UNSUBSCRIBE) | Child version wins |
| **Extensions** | Yes | `Name` | Child version wins |
| **Verifications** | Yes (special) | `Name` | Child inherits parent's `ParseDirective` if its own is nil; `Values` are merged by `Extension` field |

**Key implication: Empty arrays inherit everything.** If the child defines `"headers": []`, all parent headers are still inherited because the empty map has no conflicts. This means:

```json
// This child collection DOES inherit parent's headers, parse_directives, etc.
{
  "collection_data": {"api_interface": "rest", "type": "POST", "add_on": ""},
  "apis": [],
  "headers": [],           // ← Parent headers are MERGED in (not lost)
  "parse_directives": [],  // ← Parent directives are MERGED in
  "extensions": [],        // ← Parent extensions are MERGED in
  "verifications": []      // ← Parent verifications are MERGED in
}
```

**Verification special case:** When a child defines a verification with the same `name` as a parent but with `ParseDirective: null`, the child inherits the parent's `ParseDirective` and merges `Values` (child values take precedence when the `Extension` field matches). This is why testnet specs can override just the `expected_value` of a chain-id verification:

```json
// Child testnet spec — inherits ParseDirective from parent, overrides expected_value
{
  "name": "chain-id",
  "values": [{"expected_value": "1"}]  // Parent's ParseDirective is adopted automatically
}
```

##### Practical Examples

**Example 1: Base Chain (Full Automatic Inheritance)**
```bash
# Base only defines main collection
# Result: Gets debug, trace, and bundler add-ons for FREE from ETH1
```

**Example 2: Arbitrum (Custom Add-on + Automatic Inheritance)**
```json
{
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {"add_on": ""},
      "apis": [/* custom APIs */]
    },
    {
      "collection_data": {"add_on": "arbtrace"},  // Arbitrum-specific
      "apis": [/* arb_trace APIs */]
    }
    // NO debug defined - gets ETH1's debug automatically
    // NO trace defined - gets ETH1's trace automatically
  ]
}
```

**Example 3: Evmos (Selective Disabling)**
```json
{
  "imports": ["ETH1"],
  "api_collections": [
    {
      "collection_data": {"add_on": "debug"},
      "apis": [
        {"name": "debug_getRawBlock", "enabled": false},
        {"name": "debug_traceTransaction", "enabled": false}
        // All other debug APIs inherited as-is from ETH1
      ]
    }
  ]
}
```
Why? Some debug APIs don't work on Evmos, so they explicitly disable them.

##### Decision Matrix: Should You Define a Collection?

| Scenario | Action | Example |
|----------|--------|---------|
| You want ALL parent APIs unchanged | DON'T define the collection | Base importing ETH1 debug |
| You want to disable specific APIs | DEFINE the collection with `enabled: false` | Evmos disabling debug APIs |
| You want to change CU values | DEFINE the collection with custom CU | Optimized chain |
| You want custom verifications | DEFINE the collection with custom verifications | Chain-specific checks |
| You want a chain-specific add-on | DEFINE a NEW collection with unique `add_on` | Arbitrum's arbtrace |
| You want to add new APIs to existing add-on | DEFINE the collection with additional APIs | Fantom's trace APIs |

##### Common Mistakes to Avoid

❌ **MISTAKE 1:** Manually copying all debug APIs when you just want them as-is
```json
// DON'T DO THIS if you want ETH1's debug unchanged:
{
  "collection_data": {"add_on": "debug"},
  "apis": [
    {"name": "debug_traceBlock", "compute_units": 20, ...},
    {"name": "debug_traceTransaction", "compute_units": 100, ...},
    // ... manually copying all 11 APIs
  ]
}
// Just omit the collection entirely and inherit automatically!
```

❌ **MISTAKE 2:** Thinking inheritance is all-or-nothing
```
Inheritance is per-collection based on CollectionData matching!
```

❌ **MISTAKE 3:** Not understanding that `add_on` field determines collection identity
```json
// These are DIFFERENT collections (won't merge):
{"add_on": ""}      // Main collection
{"add_on": "debug"} // Debug collection
{"add_on": "trace"} // Trace collection
```

✅ **BEST PRACTICE:** Only define collections when you need to customize them. Let automatic inheritance handle the rest.

##### Implementation Reference

For those interested in the code:

1. **Collection Matching:** `proto/lavanet/lava/spec/api_collection.proto` defines `CollectionData`
2. **Inheritance Logic:** `x/spec/types/expand.go` - `DoExpandSpec` function (lines 13-101)
3. **Collection Combining:** `x/spec/types/spec.go` - `CombineCollections` function (lines 202-243)
4. **API Merging:** `x/spec/types/api_collection.go` - `InheritAllFields` and `CombineWithOthers` functions
5. **Combinable Interface:** `x/spec/types/combinable.go` - defines how APIs, headers, verifications, etc. are merged

**Algorithm Summary:**
1. Parse parent specs recursively (DFS)
2. Group parent collections by `CollectionData` (including `add_on`)
3. For each child collection: merge with matching parent collections
4. For leftover parent collections (no match in child): append entirely to child spec

#### Step 3.2: Configure Each API Method
**Objective**: Create accurate configuration for every API

**For Each API Method, Define**:

##### 1. Basic Properties
```json
{
  "name": "method_name",
  "enabled": true,
  "compute_units": 10,
  "extra_compute_units": 0
}
```

**Compute Units Guidelines**:

Align with established specs (ETH1, TENDERMINT) for consistency across the Lava network. When in doubt, use these reference values:

| Category | CU | Reference | Examples |
|----------|-----|-----------|----------|
| Simple reads (no block param) | 10 | ETH1, TENDERMINT | chainId, blockNumber, version |
| Block/transaction queries | 20 | ETH1 | getBlockByNumber, getBlockByHash, getBalance, getTransactionReceipt |
| Transaction submission (stateful) | 10 | ETH1, TENDERMINT | sendRawTransaction, broadcast_tx_sync/commit |
| Complex queries | 60-100 | ETH1 | getLogs (80), estimateGas (100) |
| Traces / debug | 100-200 | ETH1 | debug_traceBlock (100-200) |
| Block traces | 200-500 | ETH1 | debug_traceBlockByNumber (500) |
| Subscriptions | 1000 | ETH1, TENDERMINT | eth_subscribe, subscribe |
| Heavy ops (full scan) | 500-5000 | ETH1 | txpool_content (5000), gettxoutsetinfo (500) |

**Key principles**:
- **Transaction submission** = 10 CU (both ETH1 and TENDERMINT use 10 for sendRawTransaction/broadcast_tx)
- **Block queries** = 20 CU in ETH1; TENDERMINT uses 10 for most block ops — prefer 20 for block-heavy chains
- **Mempool/mempool-like** = 20 CU for list queries; 60-80 for complex range queries (getLogs equivalent)
- **Benchmark when uncertain** — runtime <10ms → 10 CU; 10-50ms → 20 CU; 50-200ms → 60-100 CU; >200ms → 100+

##### 2. Block Parsing
**Identify Block Reference Location**:

**No block parameter** (e.g., `eth_chainId`):
```json
{
  "block_parsing": {
    "parser_arg": [""],
    "parser_func": "EMPTY"
  }
}
```

**Uses "latest" implicitly** (e.g., `eth_blockNumber`):
```json
{
  "block_parsing": {
    "parser_arg": ["latest"],
    "parser_func": "DEFAULT"
  }
}
```

**Block in specific argument position** (e.g., `eth_getBlockByNumber` - position 0):
```json
{
  "block_parsing": {
    "parser_arg": ["0"],
    "parser_func": "PARSE_BY_ARG"
  }
}
```

**Block in later position** (e.g., `eth_getBalance` - address at 0, block at 1):
```json
{
  "block_parsing": {
    "parser_arg": ["1"],
    "parser_func": "PARSE_BY_ARG"
  }
}
```

**Block in nested object** (e.g., `eth_getLogs` with `toBlock` field):
```json
{
  "block_parsing": {
    "parser_arg": ["0", "toBlock"],
    "parser_func": "PARSE_CANONICAL"
  }
}
```

**Block in dictionary or array** (e.g., StarkNet style):
```json
{
  "block_parsing": {
    "parser_arg": ["block_number", ":", "1"],
    "parser_func": "PARSE_DICTIONARY_OR_ORDERED",
    "default_value": "latest"
  }
}
```

##### REST API Block Parsing Conventions

REST APIs handle block parsing differently from JSON-RPC. In JSON-RPC, block references are in `params[]` and can be extracted with `PARSE_BY_ARG`. In REST APIs, block references are typically in URL path segments (e.g., `/blocks/{height}`), which standard parsers cannot extract from the path template.

**The dominant pattern (~90% of REST endpoints) is `DEFAULT`:**
```json
{
  "block_parsing": {
    "parser_arg": ["latest"],
    "parser_func": "DEFAULT"
  }
}
```

This is correct for most REST endpoints because the real block extraction logic lives in the **parse directives** (`GET_BLOCKNUM`, `GET_BLOCK_BY_NUM`), not in per-endpoint `block_parsing`.

**When to use each parser in REST specs:**

| Endpoint Type | Parser | Example |
|---------------|--------|---------|
| Returns current chain state | `DEFAULT` | `/accounts/{address}`, `/pools`, `/blocks/latest` |
| Historical data by hash/ID | `DEFAULT` | `/txs/{hash}`, `/blocks/{hash_or_number}` |
| Block/height explicitly in path | `DEFAULT` or `PARSE_DICTIONARY_OR_ORDERED` | `/blocks/by_height/{block_height}` |
| Static/immutable data | `EMPTY` | `/genesis` (never changes) |
| Pure computation, no chain state | `EMPTY` | `/utils/addresses/xpub/{xpub}/{role}/{index}` |
| Mempool/pending data | `DEFAULT` | `/mempool`, `/mempool/{hash}` |

**When `PARSE_DICTIONARY_OR_ORDERED` is used in REST:**

Some REST specs extract block numbers from URL path parameters. This is done by treating path segments as ordered arguments:

```json
// Aptos: /blocks/by_height/{block_height}
{
  "block_parsing": {
    "parser_arg": ["block_height", "=", "0"],
    "parser_func": "PARSE_DICTIONARY_OR_ORDERED"
  }
}
```

**When `PARSE_CANONICAL` is used in REST (response-based):**

Some REST specs extract block information from the response body rather than the request:

```json
// Stellar: /ledgers/{sequence}
{
  "block_parsing": {
    "parser_arg": ["0", "sequence"],
    "parser_func": "PARSE_CANONICAL"
  }
}
```

**Key insight:** For REST APIs, parse directives do the heavy lifting for block tracking. Per-endpoint `block_parsing` primarily tells Lava whether to associate the request with the latest block (`DEFAULT`) or no block at all (`EMPTY`).

##### 3. Category Classification
**Determine API Characteristics**:

```json
{
  "category": {
    "deterministic": true,
    "local": false,
    "subscription": false,
    "stateful": 0,
    "hanging_api": false
  }
}
```

**Guidelines**:

**`deterministic: true`** - Use when:
- API returns same result for same block
- Examples: getBlock, getBalance, call (at specific block)
- Enables data reliability checks

**`deterministic: false`** - Use when:
- Result varies between calls
- Examples: getAccounts, mining, syncing, pending transactions

**`local: true`** - Use when:
- Data is node-specific
- Examples: filters, node version, mining status

**`subscription: true`** - Use when:
- API is for WebSocket subscriptions
- Examples: eth_subscribe, eth_unsubscribe

**`stateful: 1`** - Use when:
- API modifies blockchain state
- Examples: sendTransaction, sendRawTransaction
- Note: Use integer 1, not boolean

**`hanging_api: true`** - Use when:
- API waits for new block creation
- Often combined with stateful
- Examples: sendTransaction (waits for confirmation)

##### 4. Optional Advanced Configuration

**Timeout for slow operations**:
```json
{
  "timeout_ms": 20000
}
```

**Custom parsing for specific fields**:
```json
{
  "parsers": [
    {
      "parse_path": ".params.[0].fromBlock",
      "parse_type": "BLOCK_EARLIEST"
    },
    {
      "parse_path": ".params.[0].toBlock",
      "parse_type": "BLOCK_LATEST"
    }
  ]
}
```

#### Step 3.3: Create API Collections
**Objective**: Group APIs by interface and add-on type

**IMPORTANT NOTE:** If you are importing from another spec (e.g., ETH1), you do NOT need to define collections that you want to inherit as-is. Review Step 3.1a to understand automatic vs override inheritance before creating collections.

**When to Define Collections:**
- You need to add chain-specific APIs to the main collection
- You need to override/customize inherited APIs (change CU, disable APIs, etc.)
- You need to create a new chain-specific add-on (e.g., Arbitrum's `arbtrace`)
- You are NOT importing from another spec (must define everything)

**When NOT to Define Collections:**
- You want to inherit all APIs from parent spec unchanged (e.g., debug, trace from ETH1)
- The parent spec already has what you need

**Basic Structure**:
```json
{
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [ /* API definitions */ ],
      "headers": [],
      "inheritance_apis": [],
      "parse_directives": [ /* See Step 3.4 */ ],
      "verifications": [ /* See Step 2.3 */ ],
      "extensions": [ /* See Step 3.5 */ ]
    }
  ]
}
```

**Multiple Collections Pattern** (Only for base specs like ETH1, or when customizing):
```json
{
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""
      },
      "apis": [ /* Standard APIs */ ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "debug"
      },
      "apis": [ /* Debug APIs */ ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "trace"
      },
      "apis": [ /* Trace APIs */ ]
    }
  ]
}
```

**⚠️ NOTE:** If you're inheriting from ETH1 and want debug/trace as-is, **DO NOT** define debug/trace collections. They'll be inherited automatically. Only define them if you need to customize.

**Example: Inheriting Chain (Most Common)**
```json
{
  "index": "FANTOM",
  "imports": ["ETH1"],  // Gets ALL ETH1 collections automatically
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": ""  // Only defining main collection with Fantom-specific APIs
      },
      "apis": [
        {"name": "ftm_currentEpoch", ...},
        {"name": "dag_getEvent", ...}
        // ETH1's standard APIs (eth_*) are inherited and merged here
      ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "",
        "type": "POST",
        "add_on": "trace"  // Defining trace to ADD Fantom-specific trace APIs
      },
      "apis": [
        {"name": "trace_get", ...}  // Fantom-specific
        // ETH1's trace APIs are ALSO inherited and merged here
      ]
    }
    // NO debug collection defined = inherits ALL debug APIs from ETH1 automatically
  ]
}
```

**Version-Specific Collections** (e.g., StarkNet):
```json
{
  "api_collections": [
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "/rpc/v0_8",
        "type": "POST",
        "add_on": ""
      },
      "inheritance_apis": [
        {
          "api_interface": "jsonrpc",
          "internal_path": "",
          "type": "POST",
          "add_on": ""
        }
      ]
    },
    {
      "enabled": true,
      "collection_data": {
        "api_interface": "jsonrpc",
        "internal_path": "/rpc/v0_9",
        "type": "POST",
        "add_on": ""
      },
      "inheritance_apis": [
        {
          "api_interface": "jsonrpc",
          "internal_path": "",
          "type": "POST",
          "add_on": ""
        }
      ]
    }
  ]
}
```

#### Step 3.3a: Configure Headers
**Objective**: Define how HTTP headers are handled between clients, Lava, and providers

Headers are configured at the collection level. Each header has a `name`, a `kind` that controls its behavior, and an optional `value`.

##### Header Kinds Reference

| Kind | Direction | Purpose | Example |
|------|-----------|---------|---------|
| `pass_send` | Client → Provider | Forward a client header to the provider unchanged | API keys, auth tokens |
| `pass_override` | Lava → Provider | Set a fixed header value, ignoring the client's value | Content-type for POST |
| `pass_both` | Bidirectional | Forward to provider AND read from response into metadata | Block height tracking (Cosmos gRPC) |
| `pass_reply` | Provider → Client | Pass a response header back to the client | Ledger version (Aptos) |
| `pass_ignore` | — | Explicitly ignore this header | Legacy/deprecated headers |

##### Authentication Headers

When wrapping APIs that require authentication (third-party providers, or any endpoint requiring an API key), use `pass_send` to forward the client's credentials:

```json
{
  "headers": [
    {"name": "project_id", "kind": "pass_send"}
  ]
}
```

The consumer includes the header in their request, and Lava forwards it to the provider. Lava does not store or interpret the value.

**Real-world examples:**
- **Cardano/Blockfrost**: `project_id` with `pass_send`

##### Content-Type Headers

For REST POST collections, use `pass_override` to set the required content-type:

```json
{
  "headers": [
    {"name": "content-type", "kind": "pass_override", "value": "application/cbor"}
  ]
}
```

**Real-world examples:**
- **Cardano/Blockfrost**: `application/cbor` for transaction submission
- **Stellar**: `application/x-www-form-urlencoded` for POST endpoints

##### Mixed Content-Type Handling (IMPORTANT)

A `pass_override` for content-type applies to **ALL endpoints in that collection**. If different POST endpoints require different content-types, you have two options:

**Option A: Separate collections** (recommended) — put endpoints with different content-types in separate POST collections with different `add_on` values:
```json
{
  "api_collections": [
    {
      "collection_data": {"type": "POST", "add_on": ""},
      "headers": [{"name": "content-type", "kind": "pass_override", "value": "application/cbor"}],
      "apis": [{"name": "/tx/submit", ...}]
    },
    {
      "collection_data": {"type": "POST", "add_on": "evaluate"},
      "headers": [{"name": "content-type", "kind": "pass_override", "value": "application/json"}],
      "apis": [{"name": "/utils/txs/evaluate/utxos", ...}]
    }
  ]
}
```

**Option B: Use `pass_send`** — let the client set the content-type themselves instead of overriding it. Only use this if you trust consumers to set the correct value.

**Common mistake:** Applying a blanket `pass_override` for content-type across a POST collection when one endpoint requires a different content-type. This silently breaks that endpoint.

##### Response Headers

Use `pass_reply` to forward provider response headers back to the client. This is useful when the provider includes chain-state metadata in response headers:

```json
{
  "headers": [
    {"name": "x-aptos-block-height", "kind": "pass_reply"},
    {"name": "x-aptos-ledger-version", "kind": "pass_reply"},
    {"name": "x-aptos-ledger-timestampusec", "kind": "pass_ignore"}
  ]
}
```

##### Block Height Metadata Headers

For gRPC APIs (especially Cosmos SDK chains), use `pass_both` with `SET_LATEST_IN_METADATA` to track block height through response headers:

```json
{
  "headers": [
    {
      "name": "x-cosmos-block-height",
      "kind": "pass_both",
      "function_tag": "SET_LATEST_IN_METADATA"
    }
  ]
}
```

#### Step 3.3b: Handling Disabled and Deprecated APIs
**Objective**: Correctly exclude or disable APIs that should not be served

##### Excluding APIs Entirely

Do NOT include an API in the spec if:
- It is **deprecated** by the API provider (use the non-deprecated replacement)
- It is **platform-specific** and not chain data (health checks, usage metrics, admin endpoints)
- It is served on a **different server/domain** (e.g., IPFS endpoints on `ipfs.blockfrost.io`)
- It is a **duplicate/alias** of another included endpoint

##### Disabling Inherited APIs

When importing from a parent spec, you may need to disable specific APIs that don't work on your chain. Define the collection and set `"enabled": false` on individual APIs:

```json
// Evmos pattern: disable specific debug APIs that don't work
{
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "debug"},
  "apis": [
    {"name": "debug_getRawBlock", "enabled": false, "compute_units": 1},
    {"name": "debug_getRawHeader", "enabled": false, "compute_units": 1},
    {"name": "debug_traceCall", "enabled": false, "compute_units": 1}
    // All other debug APIs inherited from ETH1 as-is
  ]
}
```

##### Disabling Entire Add-on Collections

If your chain doesn't support an entire add-on category (e.g., trace, bundler), disable the whole collection:

```json
// Celo pattern: disable entire inherited collections
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "trace"},
  "apis": []
},
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": "bundler"},
  "apis": []
}
```

##### Replacing Inherited Collections with Custom Paths

If your chain uses a different RPC path than the parent, disable inherited collections and define new ones:

```json
// Avalanche C-Chain pattern: replace parent collections with custom path
{
  "enabled": false,
  "collection_data": {"api_interface": "jsonrpc", "type": "POST", "add_on": ""}
  // Disables parent's main collection
},
{
  "enabled": true,
  "collection_data": {"api_interface": "jsonrpc", "internal_path": "/C/rpc", "type": "POST", "add_on": ""},
  "apis": [/* Chain-specific APIs */]
}
```

#### Step 3.4: Configure Parse Directives
**Objective**: Define helper functions for block operations

**Required Parse Directives**:

##### 1. GET_BLOCKNUM - Get Latest Block Number
```json
{
  "function_template": "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}",
  "function_tag": "GET_BLOCKNUM",
  "result_parsing": {
    "parser_arg": ["0"],
    "parser_func": "PARSE_BY_ARG"
  },
  "api_name": "eth_blockNumber"
}
```

##### 2. GET_BLOCK_BY_NUM - Get Block by Number
```json
{
  "function_tag": "GET_BLOCK_BY_NUM",
  "function_template": "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"0x%x\", false],\"id\":1}",
  "result_parsing": {
    "parser_arg": ["0", "hash"],
    "parser_func": "PARSE_CANONICAL",
    "encoding": "hex"
  },
  "api_name": "eth_getBlockByNumber"
}
```

##### 3. GET_EARLIEST_BLOCK - Get Earliest Available Block (for pruning check)
```json
{
  "function_template": "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"earliest\", false],\"id\":1}",
  "function_tag": "GET_EARLIEST_BLOCK",
  "result_parsing": {
    "parser_arg": ["0", "number"],
    "parser_func": "PARSE_CANONICAL",
    "encoding": "hex"
  },
  "api_name": "eth_getBlockByNumber"
}
```

##### 4. SUBSCRIBE & UNSUBSCRIBE (if applicable)
```json
{
  "function_tag": "SUBSCRIBE",
  "api_name": "eth_subscribe"
},
{
  "function_template": "{\"jsonrpc\":\"2.0\",\"method\":\"eth_unsubscribe\",\"params\":[\"%s\"],\"id\":1}",
  "function_tag": "UNSUBSCRIBE",
  "api_name": "eth_unsubscribe"
}
```

**Note**: Adjust method names and templates for non-EVM chains.

#### Step 3.5: Configure Extensions (Optional)
**Objective**: Define special service tiers like archive nodes

**Archive Node Extension**:
```json
{
  "extensions": [
    {
      "name": "archive",
      "cu_multiplier": 5,
      "rule": {
        "block": 127
      }
    }
  ]
}
```

**Explanation**:
- `cu_multiplier`: CU cost multiplier for this extension (typically 5x for archive)
- `rule.block`: Block distance threshold - requests for blocks older than 127 blocks from latest require archive extension

**Pruning Verification** (add to verifications):
```json
{
  "name": "pruning",
  "parse_directive": {
    "function_tag": "GET_EARLIEST_BLOCK"
  },
  "values": [
    {
      "latest_distance": 128
    },
    {
      "extension": "archive",
      "expected_value": "0x0"
    }
  ]
}
```

### Phase 4: Testing & Validation

#### Step 4.1: Syntax Validation
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

#### Step 4.2: API Testing
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

4. **Test Verifications**:
   - [ ] Run chain-id verification against mainnet and testnet
   - [ ] Confirm returned value matches expected_value
   - [ ] Test any additional verifications

#### Step 4.3: Data Reliability Testing
**Objective**: Verify deterministic APIs return consistent results

**Tasks**:
- [ ] Identify all APIs marked as deterministic
- [ ] For each deterministic API:
  1. Call with same block parameter multiple times
  2. Verify identical responses
  3. Confirm deterministic flag is appropriate
- [ ] Verify non-deterministic APIs that vary between calls are flagged correctly

#### Step 4.4: Compute Units Validation
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

#### Step 4.5: Create Test Plan Document
**Objective**: Document all testing performed

**Template**:
```markdown
# Test Plan for [CHAIN_NAME] Spec

## Test Environment
- RPC Endpoint: [URL]
- Block Range Tested: [start] - [end]
- Test Date: [date]

## API Test Results

### API: method_name
- ✅ Syntax valid
- ✅ Returns expected response
- ✅ Block parsing correct
- ✅ Determinism verified (if applicable)
- ✅ CU appropriate (avg response time: XXms)
- Notes: [any observations]

[Repeat for each API]

## Parse Directives
- ✅ GET_BLOCKNUM: Returns current block
- ✅ GET_BLOCK_BY_NUM: Returns correct block hash
- ✅ GET_EARLIEST_BLOCK: Returns earliest available block

## Verifications
- ✅ Chain ID: Expected [value], Got [value]
- ✅ Pruning check: [results]

## Issues Found
1. [Issue description and resolution]
2. [Issue description and resolution]

## Final Checklist
- [ ] All APIs tested and working
- [ ] Block parsing validated
- [ ] Verifications pass
- [ ] CU values benchmarked
- [ ] Documentation complete
```

### Phase 5: Documentation

#### Step 5.1: Create Spec Documentation
**Objective**: Provide comprehensive documentation for the spec

**Create**: `docs/[CHAINNAME]/SPEC_IMPLEMENTATION.md`

**Template**:
```markdown
# [CHAIN_NAME] Specification Implementation

## Overview
[Brief description of the blockchain and why this spec is needed]

## Network Information
- **Blockchain**: [Chain Name]
- **Consensus**: [PoW/PoS/BFT/etc]
- **Block Time**: [time] seconds
- **Finality**: [description]
- **RPC Protocol**: [JSON-RPC/REST/gRPC]

## Spec Details
- **Index**: `CHAININDEX`
- **Mainnet Index**: `CHAININDEX`
- **Testnet Index**: `CHAININDEXT`
- **Inherits From**: [parent spec or "None"]

## Network Parameters
- **Average Block Time**: [value]ms
- **Block Distance for Finalized Data**: [value]
- **Blocks in Finalization Proof**: [value]
- **Allowed Block Lag for QoS**: [value]
- **Reliability Threshold**: 268435455
- **Data Reliability**: Enabled

## API Collections

### Standard APIs
[List of standard APIs with brief descriptions]

### Chain-Specific APIs
[List of chain-specific APIs with descriptions]

### Add-ons
- **debug**: [Description of debug APIs]
- **trace**: [Description of trace APIs]
- [Other add-ons]

## Verifications
- **Chain ID**: [value] (mainnet), [value] (testnet)
- **Pruning**: Archive extension required for blocks older than 127

## Extensions
- **archive**: 5x CU multiplier for historical data beyond 127 blocks

## Testing
[Summary of testing performed - reference test plan]

## Known Limitations
[Any known issues or limitations]

## References
- [Official documentation URL]
- [RPC specification URL]
- [GitHub repository]
```

#### Step 5.2: Create API Reference
**Objective**: Document each API method in detail

**Create**: `docs/[CHAINNAME]/API_REFERENCE.md`

**Template**:
```markdown
# [CHAIN_NAME] API Reference

## API: method_name

### Description
[What this API does]

### Parameters
1. **param1** (type): [description]
2. **param2** (type): [description]

### Returns
- **return_field** (type): [description]

### Example Request
```json
{
  "jsonrpc": "2.0",
  "method": "method_name",
  "params": [param1, param2],
  "id": 1
}
```

### Example Response
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "field": "value"
  }
}
```

### Spec Configuration
- **Compute Units**: 20
- **Deterministic**: true
- **Block Parsing**: PARSE_BY_ARG at position 1
- **Category**: Read-only query

[Repeat for each API]
```

#### Step 5.3: Create Testing Guide
**Objective**: Help others test and verify the spec

**Create**: `docs/[CHAINNAME]/TESTING_GUIDE.md`

**Template**:
```markdown
# [CHAIN_NAME] Testing Guide

## Prerequisites
- Access to [Chain Name] RPC endpoint
- `curl` or similar HTTP client
- `jq` for JSON processing

## Quick Start

### 1. Validate Spec File
```bash
jq . chainname.json
```

### 2. Test Chain ID Verification
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"method_chainId","params":[],"id":1}' \
  [RPC_ENDPOINT] | jq
```
Expected: `{"result": "[expected_chain_id]"}`

### 3. Test Block Number
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"method_blockNumber","params":[],"id":1}' \
  [RPC_ENDPOINT] | jq
```

### 4. Test Block Retrieval
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"method_getBlockByNumber","params":["latest",false],"id":1}' \
  [RPC_ENDPOINT] | jq
```

## Comprehensive API Testing

[Detailed test cases for each API category]

## Automated Testing Script
[Provide a bash or python script for automated testing]
```

#### Step 5.4: Create Quick Start Guide
**Objective**: Help providers get started quickly

**Create**: `docs/[CHAINNAME]/QUICK_START.md`

**Template**:
```markdown
# [CHAIN_NAME] Quick Start

## For Providers

### 1. Node Setup
[Instructions for setting up a node for this blockchain]

### 2. RPC Configuration
[RPC endpoint configuration]

### 3. Lava Provider Setup
```bash
# Add the spec to your provider
lavad tx pairing stake-provider \
  "CHAININDEX" \
  "[STAKE_AMOUNT]" \
  "[YOUR_RPC_ENDPOINT]" \
  "[GEOLOCATION]" \
  --from "[YOUR_KEY]" \
  --chain-id "lava-mainnet-1"
```

### 4. Verification
[How to verify your provider is working correctly]

## For Consumers

### 1. Using the Lava SDK
[Code examples for consuming this spec via Lava]

### 2. Supported APIs
[List of available APIs and examples]
```

### Phase 6: Proposal Creation

#### Step 6.1: Create Proposal JSON
**Objective**: Format the spec as a governance proposal

**Structure**:
```json
{
  "proposal": {
    "title": "Add Specs: [Chain Name]",
    "description": "Adding new specification support for relaying [Chain Name] data on Lava",
    "specs": [
      {
        "index": "MAINNETINDEX",
        "name": "[chain name] mainnet",
        "enabled": true,
        // ... all spec configuration
      },
      {
        "index": "TESTNETINDEX",
        "name": "[chain name] testnet",
        "enabled": true,
        "imports": ["MAINNETINDEX"],  // Inherit from mainnet
        // ... minimal testnet overrides
      }
    ]
  },
  "deposit": "10000000ulava"
}
```

**Proposal Guidelines**:
- Include both mainnet and testnet specs in one proposal
- Testnet should inherit from mainnet (use `imports`)
- Only override what's different in testnet (typically just verifications)
- Deposit: `10000000ulava` (10,000 LAVA) is the mandated standard — flag any other value

#### Step 6.2: Save Proposal Files
**Objective**: Store proposal in correct locations

**Save Location**:
```bash
# All specs live flat at the repo root, one file per chain. A single
# <chain>.json holds both the mainnet and testnet entries under proposal.specs[].
chainname.json
```

#### Step 6.3: Create Proposal Description
**Objective**: Write compelling proposal for governance

**Template** (`PROPOSAL_DESCRIPTION.md`):
```markdown
# Add Specs: [Chain Name]

## Summary
This proposal adds support for [Chain Name] ([MAINNETINDEX]/[TESTNETINDEX]) to the Lava Network, enabling providers to serve [Chain Name] RPC requests through Lava's decentralized infrastructure.

## Motivation
[Why this chain is important - usage stats, ecosystem size, developer demand, etc.]

## Specification Details

### Network Information
- **Blockchain**: [Chain Name]
- **Consensus**: [mechanism]
- **Block Time**: [time]s
- **Finality**: [description]
- **RPC Protocol**: [type]

### Supported APIs
- **[X] Standard APIs**: [brief list]
- **[Y] Chain-Specific APIs**: [brief list]
- **Add-ons**: [debug/trace/etc if applicable]

### Configuration Highlights
- Average block time: [value]ms
- Finality distance: [value] blocks
- Data reliability: Enabled
- Archive support: Available via extension

## Testing
This specification has been thoroughly tested:
- ✅ All [X] APIs validated against live [Chain Name] nodes
- ✅ Block parsing verified for accuracy
- ✅ Chain ID verification confirmed
- ✅ Data reliability mechanisms tested
- ✅ Compute units benchmarked

See full test results: [link to testing documentation]

## Economic Impact
- **Min Provider Stake**: 5,000 LAVA
- **Min Consumer Stake**: None
- **Contributor Reward**: [if applicable]

## Timeline
- Proposal submission: [date]
- Voting period: [duration]
- Expected activation: [date]

## References
- Specification files: [GitHub links]
- Documentation: [links]
- Testing guide: [link]
- Official [Chain Name] docs: [link]

## Contributor
[Your information if claiming contributor rewards]
```

### Phase 7: Submission & Deployment

#### Step 7.1: Pre-Submission Checklist
**Complete Final Review**:

- [ ] **File Validation**
  - [ ] JSON syntax valid
  - [ ] All required fields present
  - [ ] No duplicate API names
  - [ ] Proper indentation and formatting

- [ ] **Configuration Verification**
  - [ ] Network parameters calculated correctly
  - [ ] All APIs tested and working
  - [ ] Block parsing validated for each API
  - [ ] Verifications pass on live nodes
  - [ ] Compute units benchmarked
  - [ ] Economic parameters reasonable

- [ ] **Documentation Complete**
  - [ ] SPEC_IMPLEMENTATION.md created
  - [ ] API_REFERENCE.md created
  - [ ] TESTING_GUIDE.md created
  - [ ] QUICK_START.md created
  - [ ] All examples tested

- [ ] **Testnet vs Mainnet**
  - [ ] Mainnet spec complete
  - [ ] Testnet spec inherits correctly
  - [ ] Chain IDs verified for both networks
  - [ ] Both tested on respective networks

- [ ] **Governance Prep**
  - [ ] Proposal JSON formatted correctly
  - [ ] Proposal description written
  - [ ] Deposit amount confirmed (`10000000ulava`)
  - [ ] Community feedback gathered (if applicable)

#### Step 7.2: Submit to GitHub
**Objective**: Create pull request for spec inclusion

**Steps**:
1. **Fork the Lava repository**
```bash
git clone https://github.com/lavanet/lava.git
cd lava
git checkout -b add-spec-chainname
```

2. **Add your spec files**
```bash
# Add spec proposal
cp /path/to/chainname.json chainname.json

# Add documentation
mkdir -p specs/docs/CHAINNAME
cp /path/to/docs/* specs/docs/CHAINNAME/

# Update main README if needed
# Add your chain to the list of supported chains
```

3. **Commit changes**
```bash
git add chainname.json
git add specs/docs/CHAINNAME/
git commit -m "Add specification for [Chain Name]

- Add mainnet spec (MAINNETINDEX)
- Add testnet spec (TESTNETINDEX)
- Include comprehensive documentation
- All APIs tested and validated
"
```

4. **Push and create PR**
```bash
git push origin add-spec-chainname
# Create PR via GitHub web interface
```

5. **PR Description Template**:
```markdown
## Description
This PR adds support for [Chain Name] to Lava Network.

## Changes
- Added spec file: `chainname.json`
- Added documentation in `specs/docs/CHAINNAME/`
- Includes [X] APIs ([Y] standard, [Z] chain-specific)

## Testing
- ✅ All APIs validated against live nodes
- ✅ Block parsing verified
- ✅ Verifications confirmed
- ✅ Documentation reviewed

## Checklist
- [x] Spec file validates with `jq`
- [x] All APIs tested
- [x] Documentation complete
- [x] Ready for governance proposal

## Related Issues
[Link any related issues or discussions]
```

#### Step 7.3: Submit Governance Proposal
**Objective**: Submit spec to on-chain governance

**Command**:
```bash
lavad tx gov submit-legacy-proposal spec-add \
  "chainname.json" \
  -y \
  --from "YOUR_ACCOUNT_NAME" \
  --gas-adjustment "1.5" \
  --gas "auto" \
  --gas-prices "0.0001ulava" \
  --chain-id "lava-mainnet-1" \
  --node "https://public-rpc.lavanet.xyz:443/rpc/"
```

**Monitor Proposal**:
```bash
# Get proposal ID from transaction
lavad query gov proposals --chain-id "lava-mainnet-1"

# Check proposal status
lavad query gov proposal [PROPOSAL_ID] --chain-id "lava-mainnet-1"

# Check votes
lavad query gov votes [PROPOSAL_ID] --chain-id "lava-mainnet-1"
```

**Voting Period Actions**:
- [ ] Monitor votes and tally
- [ ] Respond to community questions
- [ ] Provide additional testing evidence if requested
- [ ] Address any concerns raised by validators

#### Step 7.4: Post-Approval Actions
**Objective**: Finalize spec deployment after governance approval

**Once Proposal Passes**:

1. **File Location**: this repo is flat — the spec already lives at the repo
   root as `<index-lowercased>.json` (e.g. `katana.json`). There is no
   undeployed/mainnet-1 directory move; nothing to relocate after approval.

2. **Update Documentation**:
   - Add deployment date to docs
   - Update status to "Active"
   - Add on-chain proposal link

3. **Notify Community**:
   - Announce on Discord/Telegram
   - Update website/docs
   - Create provider onboarding materials

4. **Monitor Initial Providers**:
   - Track first providers staking
   - Monitor for any issues
   - Gather feedback

5. **Create Testnet PR** (if applicable):
```bash
# If testnet wasn't included in original proposal
# Create separate testnet proposal
```

### Phase 8: Maintenance & Updates

#### Step 8.1: Monitor Spec Performance
**Ongoing Tasks**:
- [ ] Track provider adoption
- [ ] Monitor relay success rates
- [ ] Collect feedback on API performance
- [ ] Review CU consumption patterns
- [ ] Check for any API failures or issues

#### Step 8.2: Update Process
**When Updates Are Needed**:

**Types of Updates**:
1. **Add New APIs**: When blockchain adds new RPC methods
2. **Adjust CU**: If APIs prove more/less expensive than estimated
3. **Fix Issues**: Correct parsing errors or configuration mistakes
4. **Add Extensions**: Support new provider capabilities

**Update Process**:
1. Create updated spec JSON
2. Test changes thoroughly
3. Document what changed and why
4. Submit new governance proposal with clear changelog
5. Update documentation

**Update Proposal Template**:
```json
{
  "proposal": {
    "title": "Update Specs: [Chain Name] - [Brief Description]",
    "description": "Updating [Chain Name] specification to [reason]",
    "specs": [
      {
        // Updated spec with changes
      }
    ]
  },
  "deposit": "10000000ulava"
}
```

#### Step 8.3: Versioning & Changelog
**Maintain History**:

**Create**: `docs/[CHAINNAME]/CHANGELOG.md`
```markdown
# [CHAIN_NAME] Specification Changelog

## Version 2 - [Date]
### Added
- New API: method_name
- Support for feature X

### Changed
- Increased CU for method_name from 20 to 50
- Updated block parsing for method_name

### Fixed
- Corrected parser_arg for method_name
- Fixed chain-id verification encoding

### Governance
- Proposal: [link]
- Voting Period: [dates]
- Result: PASSED

## Version 1 - [Date]
### Initial Release
- Added [X] APIs
- Supports mainnet and testnet
- Governance Proposal: [link]
```

---

## Best Practices Summary

### Do's ✅
- **Test extensively** against live nodes before submission
- **Document everything** - future maintainers will thank you
- **Use inheritance** when appropriate to reduce duplication (see Step 3.1a for detailed mechanics)
- **Understand collection inheritance** - only define collections you need to customize
- **Let automatic inheritance work** - don't manually copy APIs from parent specs
- **Start with testnet** if unsure - lower stakes for testing
- **Engage community** early for feedback and support
- **Be precise** with block parsing - incorrect parsing breaks reliability
- **Benchmark accurately** - CU values affect provider economics
- **Include examples** in documentation for clarity
- **Version control** - track all changes with clear commits
- **Monitor after deployment** - be ready to issue updates

### Don'ts ❌
- **Don't guess** at parameters - measure and verify
- **Don't skip testing** - untested specs can harm the network
- **Don't over-complicate** - simpler specs are easier to maintain
- **Don't manually copy inherited collections** - if you want debug/trace from ETH1 unchanged, omit those collections entirely
- **Don't define collections unnecessarily** - automatic inheritance is your friend
- **Don't ignore existing patterns** - follow conventions from similar chains
- **Don't set deterministic=true** for non-deterministic APIs
- **Don't forget testnet** - providers need testing environments
- **Don't use mock data** - always test with real blockchain data
- **Don't rush governance** - give community time to review
- **Don't abandon** - be available for questions and updates
- **Don't duplicate work** - check if similar spec already exists

### Common Pitfalls to Avoid
1. **Misunderstanding Inheritance**: Manually defining collections that should be inherited automatically (read Step 3.1a carefully!)
2. **Incorrect Block Parsing**: Most common issue - verify parser positions. For REST APIs, use DEFAULT for most endpoints and EMPTY only for static/computation endpoints (see REST API Block Parsing Conventions)
3. **Wrong Determinism Flags**: Breaks data reliability if incorrect
4. **Unrealistic CU Values**: Causes economic imbalance — cross-check with `ethereum.json` and `tendermint.json` for similar operations
5. **Unnecessary Collection Definitions**: Defining debug/trace add-ons when inheriting from ETH1 unchanged
6. **Missing Verifications**: Allows invalid providers on network
7. **Incorrect Chain IDs**: Breaks chain verification entirely
8. **Poor Documentation**: Causes confusion and low adoption
9. **Inadequate Testing**: Leads to post-deployment issues
10. **Forgetting Extensions**: Archive nodes need proper configuration + pruning verification + GET_EARLIEST_BLOCK directive
11. **Hardcoded Values**: Use proper parameter references
12. **Incomplete API Coverage**: Frustrates users needing missing APIs
13. **Not Understanding CollectionData Matching**: Each `add_on` value creates a separate collection that inherits independently
14. **Blanket Content-Type Override**: Applying `pass_override` for content-type across a POST collection when different endpoints require different content-types (see Step 3.3a)
15. **Including Deprecated APIs**: Always check if the API provider has deprecated endpoints — use the non-deprecated replacement instead
16. **Including Platform-Specific APIs**: Health checks, usage metrics, and admin endpoints from third-party providers are not chain data and should be excluded
17. **Assuming Override Semantics**: All collection fields (headers, extensions, parse_directives, verifications) use **merge** semantics, not override. Empty arrays inherit parent values — they don't zero them out (see Step 3.1a)

---

## Resources

### Internal Resources
- **Spec Protobuf**: `proto/lavanet/lava/spec/spec.proto`
- **ServiceApi Protobuf**: `proto/lavanet/lava/spec/service_api.proto`
- **Existing Specs**: ``
- **CU Pricing Reference**: `ethereum.json` (ETH1), `tendermint.json` (TENDERMINT) — use for baseline alignment
- **Example Documentation**: `docs/KASPA/`, `docs/STRK/`

### External Resources
- **Lava Documentation**: https://docs.lavanet.xyz
- **Lava GitHub**: https://github.com/lavanet/lava
- **Governance Portal**: https://governance.lavanet.xyz
- **Community Discord**: [link]
- **Provider Documentation**: https://docs.lavanet.xyz/provider

### Tools
- **JSON Validator**: https://jsonlint.com
- **jq**: https://stedolan.github.io/jq/
- **curl**: For RPC testing
- **Postman**: For API testing and documentation

---

## Appendix

### A. Parser Functions Reference

**EMPTY**
- Use: API has no block parameter
- Example: `eth_chainId`, `net_version`

**DEFAULT**
- Use: API implicitly uses "latest" block
- Example: `eth_blockNumber`, `eth_syncing`

**PARSE_BY_ARG**
- Use: Block is at specific argument position
- Format: `["0"]` for first param, `["1"]` for second, etc.
- Example: `eth_getBlockByNumber` (position 0), `eth_getBalance` (position 1)

**PARSE_CANONICAL**
- Use: Block is in nested object structure
- Format: `["0", "fieldName"]` for `params[0].fieldName`
- Example: `eth_getLogs` with `["0", "toBlock"]`

**PARSE_DICTIONARY_OR_ORDERED**
- Use: Supports both dictionary and array parameters
- Format: `["field_name", ":", "position"]`
- Example: `["block_number", ":", "1"]` for StarkNet-style APIs

### B. Encoding Reference

**hex**
- Use: For hexadecimal values (common in Ethereum)
- Example: `0x1` for chain ID

**base64**
- Use: For base64-encoded values
- Example: StarkNet block hashes

**none**
- Use: Plain text/number values (default if not specified)

### C. Function Tags Reference

**GET_BLOCKNUM**
- Purpose: Get current block number
- Required: Yes

**GET_BLOCK_BY_NUM**
- Purpose: Get block details by number
- Required: Yes

**GET_EARLIEST_BLOCK**
- Purpose: Check earliest available block (for pruning)
- Required: For chains with archive extensions

**VERIFICATION**
- Purpose: Verify provider configuration
- Required: For custom verifications

**SUBSCRIBE/UNSUBSCRIBE**
- Purpose: WebSocket subscription management
- Required: Only if chain supports subscriptions

### D. Category Values Quick Reference

```json
{
  "category": {
    "deterministic": true,      // Same result every call for same block
    "local": false,             // Node-local data (not chain state)
    "subscription": false,      // WebSocket subscription API
    "stateful": 0,             // 1 for transaction APIs, 0 for reads
    "hanging_api": false       // true if waits for block creation
  }
}
```

**Common Patterns**:
- Read query: `{deterministic: true, local: false, subscription: false, stateful: 0}`
- Transaction: `{deterministic: false, local: false, subscription: false, stateful: 1, hanging_api: true}`
- Subscription: `{deterministic: false, local: true, subscription: true, stateful: 0}`
- Node info: `{deterministic: false, local: true, subscription: false, stateful: 0}`

### E. Header Kinds Reference

| Kind | Direction | Purpose |
|------|-----------|---------|
| `pass_send` | Client → Provider | Forward client header to provider (auth tokens, API keys) |
| `pass_override` | Lava → Provider | Set a fixed value, ignoring client's (content-type) |
| `pass_both` | Bidirectional | Forward to provider AND read from response metadata |
| `pass_reply` | Provider → Client | Pass provider response header back to client |
| `pass_ignore` | — | Explicitly ignore this header |

**Common Configurations**:
- Authentication: `{"name": "project_id", "kind": "pass_send"}`
- Content-Type: `{"name": "content-type", "kind": "pass_override", "value": "application/cbor"}`
- Block Height (gRPC): `{"name": "x-cosmos-block-height", "kind": "pass_both", "function_tag": "SET_LATEST_IN_METADATA"}`
- Response Metadata: `{"name": "x-aptos-block-height", "kind": "pass_reply"}`

### F. REST vs JSON-RPC Quick Reference

| Aspect | REST Specs | JSON-RPC Specs |
|--------|-----------|----------------|
| Dominant block parser | `DEFAULT` (~90%) | `PARSE_BY_ARG`, `PARSE_CANONICAL` |
| Block reference location | URL path segments | `params[]` array |
| Block extraction | Via parse directives | Via per-endpoint block_parsing |
| Content-type handling | May need `pass_override` headers | Usually not needed |
| Authentication | Often `pass_send` headers | Rarely needed |

---

## Getting Help

If you encounter issues or have questions:

1. **Check existing specs** for similar chains
2. **Review documentation** in `docs/`
3. **Ask in Discord** - Lava community channel
4. **Open GitHub issue** for spec-related questions
5. **Consult Lava docs** at https://docs.lavanet.xyz

---

*Last Updated: [Date]*
*Version: 1.0*
*Maintainer: [Your name/team]*

<!-- END-OF-GUIDE-SENTINEL -->


