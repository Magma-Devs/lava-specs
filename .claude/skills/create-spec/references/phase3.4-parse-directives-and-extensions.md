# Phase 3.4: Configure Parse Directives and Extensions

**Objective**: Define helper functions for block operations

**Required Parse Directives**:

### 1. GET_BLOCKNUM - Get Latest Block Number
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

### 2. GET_BLOCK_BY_NUM - Get Block by Number
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

### 3. GET_EARLIEST_BLOCK - Get Earliest Available Block (for pruning check)
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

### 4. SUBSCRIBE & UNSUBSCRIBE (if applicable)
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

## Step 3.4a: Configure Extensions (Optional)
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

---

## Appended from SPEC_GUIDE.md §Archive Extension Recalibration for Fast Chains (lines 325-375)

```

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

END-OF-PHASE3.4-SENTINEL
