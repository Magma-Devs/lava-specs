# Appendix: Reference Tables

Sourced verbatim from `.claude/skills/review-spec/SPEC_GUIDE.md` lines 2106-2199.
Quick-lookup tables for parser functions, encoding, function tags, category values, and header kinds.

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
    "stateful": 0,             // 1 for transaction APIs, 0 for reads
    "hanging_api": false       // true if waits for block creation
  }
}
```

**Common Patterns**:
- Read query: `{deterministic: true, stateful: 0}`
- Transaction: `{deterministic: false, stateful: 1, hanging_api: true}`
- Subscription: detected from a `SUBSCRIBE`/`UNSUBSCRIBE` parse directive, not a category flag; the method's category is typically `{deterministic: false, stateful: 0}`
- Node info: `{deterministic: false, stateful: 0}` (node-local data; the `local` flag was removed from the model)

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

END-OF-APPENDIX-SENTINEL
