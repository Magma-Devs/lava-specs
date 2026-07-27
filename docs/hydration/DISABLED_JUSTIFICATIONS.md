# Hydration (HYDRATION / HYDRATIONT) — Disabled API Justifications

Every `enabled: false` entry in `hydration.json` must have a positive-evidence row here —
official docs explicitly marking the method unsupported/removed, or the chain's node-client
not implementing/refusing it, cited with a source. Runtime probe results alone (`-32601`,
HTTP 404/501/5xx, timeouts) are NOT sufficient evidence.

All 13 disabled entries fall under a single, documented Substrate mechanism: they are
**node-local RPCs gated by the `--rpc-methods=Safe` policy**, which every public endpoint
runs. The node does not merely fail them — it refuses them with an explicit classification:

```
$ curl -s -X POST https://rpc.hydradx.cloud -d \
    '{"jsonrpc":"2.0","method":"author_hasKey","params":["0x00","aura"],"id":1}'
{"error":{"code":-32601,"message":"RPC call is unsafe to be called externally"}}

# control — an unknown method returns a different message:
{"error":{"code":-32601,"message":"Method not found"}}
```

That message is the node's own safety classification, not an absence artifact. In
`polkadot-sdk`, these methods carry the `with_extensions` annotation in
`substrate/client/rpc-api` (`author`, `offchain`, `state`, `system`), marking them as
requiring elevated permissions rather than being part of the public surface.

Beyond safety, they are also **semantically unroutable across a provider set**: each
answers about, or mutates, one particular node's keystore, offchain storage, peer set or
log configuration — not chain state. Two providers would legitimately return different
answers, so relaying them through Lava is incoherent by construction.

**In-repo precedent:** the merged `POLKADOTASSETHUB` spec (`polkadot_asset_hub.json`)
disables this same set. Hydration's 13 are an exact subset of its 14 — the only extra there
is `author_rotateKeysWithOwner`, which Hydration does not declare.

| name | interface | evidence-type | source | justification |
|---|---|---|---|---|
| `author_hasKey` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/author` (`with_extensions`) · live node: `"RPC call is unsafe to be called externally"` | Queries whether a key is in **this node's** keystore. Safe-policy gated; node-local, so different providers answer differently. Disabled in `POLKADOTASSETHUB`. |
| `author_hasSessionKeys` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/author` (`with_extensions`) | Same keystore query for session keys. Safe-policy gated and node-local. Disabled in `POLKADOTASSETHUB`. |
| `author_insertKey` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/author` (`with_extensions`) | **Writes** a private key into this node's keystore. Never valid to relay: it would target one arbitrary provider and is a key-custody hazard. Disabled in `POLKADOTASSETHUB`. |
| `author_rotateKeys` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/author` (`with_extensions`) | Generates and stores new session keys on this node — a validator-operator action, not chain state. Disabled in `POLKADOTASSETHUB`. |
| `offchain_localStorageGet` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/offchain` (`with_extensions`) | Reads **per-node** offchain-worker storage, which is not consensus state; providers hold different contents. Safe-policy gated. Disabled in `POLKADOTASSETHUB`. |
| `offchain_localStorageSet` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/offchain` (`with_extensions`) | Writes per-node offchain storage. Mutates one provider's local state only. Disabled in `POLKADOTASSETHUB`. |
| `offchain_localStorageClear` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/offchain` (`with_extensions`) | Clears per-node offchain storage. Same node-local mutation class. Disabled in `POLKADOTASSETHUB`. |
| `state_getPairs` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/state` (`with_extensions`) | Dumps every key/value under a storage prefix — unbounded response, DoS-class, which is why it is Safe-policy gated on public endpoints. Disabled in `POLKADOTASSETHUB`. |
| `state_traceBlock` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/state` (`with_extensions`) | Full block re-execution tracing; unbounded cost and gated by the Safe policy. Disabled in `POLKADOTASSETHUB`. |
| `system_addReservedPeer` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/system` (`with_extensions`) · live node: `"RPC call is unsafe to be called externally"` | Mutates **this node's** reserved-peer set — operator administration, not chain state. Disabled in `POLKADOTASSETHUB`. |
| `system_removeReservedPeer` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/system` (`with_extensions`) | Inverse of the above; same node-local administrative class. Disabled in `POLKADOTASSETHUB`. |
| `system_addLogFilter` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/system` (`with_extensions`) | Changes **this node's** log-level filtering. Purely operator-side; no chain semantics. Disabled in `POLKADOTASSETHUB`. |
| `system_resetLogFilter` | jsonrpc | client-source | polkadot-sdk `substrate/client/rpc-api/src/system` (`with_extensions`) | Resets this node's log filtering. Same operator-side class. Disabled in `POLKADOTASSETHUB`. |
