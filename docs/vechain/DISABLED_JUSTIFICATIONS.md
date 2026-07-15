# VeChain (VECHAIN / VECHAINT) — Disabled API Justifications

Every `enabled: false` entry in `vechain.json` must have a positive-evidence row here —
official docs explicitly marking the method unsupported/removed, or the chain's
node-client not implementing it, cited with a URL. Runtime probe results alone
(`-32601`, HTTP 404/501/5xx, timeouts) are NOT sufficient evidence.

| name | interface | evidence-type | source | justification |
|---|---|---|---|---|
| `eth_signTypedData_v4` | jsonrpc | client-source | https://eips.ethereum.org/EIPS/eip-712 · https://eips.ethereum.org/EIPS/eip-1193 | EIP-712 typed-data signing needs a client-side wallet/private key; a stateless relay gateway holds no signer. VeChain's own node returns the semantic error `"Provider must be defined with a wallet"` (not a free-tier `-32601`), confirming a node backend cannot serve it. |
| `eth_sendTransaction` | jsonrpc | client-source | https://ethereum.org/en/developers/docs/apis/json-rpc/#eth_sendtransaction · https://eips.ethereum.org/EIPS/eip-1193 | Signs and broadcasts using a wallet the node manages; a public relay holds no unlocked accounts, so it cannot serve it (same `"Provider must be defined with a wallet"` class). Pre-signed transactions use `eth_sendRawTransaction` (kept enabled). |
| `/subscriptions/beat` | rest | docs-explicit | https://github.com/vechain/thor/blob/master/api/doc/thor.yaml | Marked `deprecated: true` in Thor's official OpenAPI (`thor.yaml`); superseded by `/subscriptions/beat2` (kept enabled), which serves the same block-beat stream in the current format. |
| `eth_requestAccounts` | jsonrpc | docs-explicit | https://eips.ethereum.org/EIPS/eip-1102 | EIP-1102 injected-provider permission prompt — a browser-wallet convention, not a node RPC method. Thor/geth-class backends do not implement it (method-not-found); it requires the same client-side wallet capability cited for `eth_signTypedData_v4`. Absent from `ethereum.json` and every other spec in this repo. |
| `evm_mine` | jsonrpc | docs-explicit | https://hardhat.org/hardhat-network/docs/reference#evm_mine | Hardhat/Ganache dev-console "mine-on-demand" method with no production meaning on VeChain (PoA produces blocks on a fixed 10 s schedule); the testnet dev gateway returns `result: null` (no-op). Not a real node capability. |
