# Endpoint Discovery (Phase 7.5 of create-spec)

You are a subagent dispatched by the create-spec orchestrator. Your job is to
find and validate an upstream endpoint for **every** interface, subscription,
and addon the resolved spec declares — and to report transparently when one
cannot be found. You run AFTER the spec is written and jq-validated (Phase 7),
so you work against the fully resolved import closure, not the leaf file.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate `<chain>.json`.
- `<chain_name>`, `<chain_family>` — for source lookups.
- `<mainnet_index>`, `<testnet_index>` — the spec indices.

## Step 1 — Derive the requirement set (dynamically, from the spec)

Never assume a fixed set. Enumerate from `<spec_path>` (and resolve imports —
the gRPC interface, ws subscriptions, and many addons are inherited and invisible
in the leaf file):

```bash
# interfaces
jq -r '.proposal.specs[].api_collections[]?.collection_data.api_interface' <spec_path> | sort -u
# addons / extensions (whatever the spec declares — chain-custom included)
jq -r '.proposal.specs[].api_collections[]? | (.collection_data.add_on // empty), (.extensions[]?.name // empty)' <spec_path> | sort -u
# interfaces that need a ws upstream (any subscription method present)
jq -r '.proposal.specs[].api_collections[]? | select([.apis[]?.category.subscription] | any) | .collection_data.api_interface' <spec_path> | sort -u
```

Resolve `imports` against the repo's base specs (`cosmossdkv50.json`,
`cosmoswasm.json`, `ethermint.json`, `ethereum.json`, `tendermint.json`, …) so
inherited interfaces/addons/subscriptions are included. Produce three lists:
**interfaces**, **subscriptions (per interface)**, **addons** — for BOTH mainnet
and testnet indices.

## Step 2 — Find candidates per requirement

Treat every requirement uniformly: walk a ranked source ladder, emit candidates,
validate each with the requirement's REAL call (not a casual ping — restricted
public nodes answer naive calls but fail router boot). On failure, try the next.

| requirement | sources (ranked) | transport / URL form | validation call |
|---|---|---|---|
| `jsonrpc` | chain docs, chainlist.org, comparenodes.com | `https://` | `eth_chainId` / `eth_blockNumber` |
| `rest` | chain docs, cosmos chain-registry, Polkachu | `https://` | a known `GET` (e.g. `/cosmos/base/tendermint/v1beta1/blocks/latest`) |
| `tendermintrpc` | chain docs, cosmos chain-registry, Polkachu | `https://` | `/status` |
| `grpc` | Polkachu `public_grpc`, cosmos chain-registry, Lavender.Five, docs | `grpcs://host:port` (TLS) **or** `grpc://host:port` plaintext (then the node-url entry needs `grpc-config.allow-insecure: true` AND the router needs `--allow-insecure-provider-dialing`); bare `host:port` is rejected | `grpcurl … cosmos.base.tendermint.v1beta1.Service/GetNodeInfo` direct (the smart-router gRPC listener has no server reflection) |
| subscription (per interface) | same sources as its interface, ws variant | `wss://…` (EVM) / `wss://…/websocket` (tendermintrpc) | ws handshake (expect `101 Switching Protocols`), then a `subscribe` round-trip |
| addon/extension (each declared) | sources of the owning interface | inherits the interface transport | a representative ENABLED method/verification from that addon's OWN collection in the spec (archive: a deep historical block; debug: `debug_traceBlockByNumber`; chain-custom: pick one of its declared methods) |

gRPC has the most footnotes only because it has the most failure modes (scarce
endpoints, two transports, restricted nodes, no router reflection) — it is one
requirement among equals, not the focus. The same discover-validate-fallback
logic applies to every row.

## Step 3 — Emit the keyed candidate list

For Phase 8 to consume, write a candidate list where each entry is
`{network, interface, kind (interface|subscription|addon), addon_name, url,
transport, source_url, validation: OK|FAIL}`. Include only validated-OK entries
as usable upstreams; keep failed ones for the evidence trail.

## Step 4 — Emit the coverage matrix (transparency gate)

One row per requirement, for mainnet and testnet:

```
| network | requirement | kind | status | endpoint | evidence |
|---|---|---|---|---|---|
| mainnet | jsonrpc | interface | TESTED_OK | https://… | eth_chainId→0x… |
| mainnet | jsonrpc/ws | subscription | TESTED_OK | wss://… | handshake 101 + subscribe ack |
| mainnet | grpc | interface | NOT_TESTABLE | — | searched Polkachu, chain-registry, Lavender.Five → none reachable |
| mainnet | archive | addon | NOT_TESTABLE | — | searched docs → no public archive node |
```

`NOT_TESTABLE` is ONLY legal with: the named sources you checked AND an
empty-or-all-failed candidate list. A missing endpoint is a transparent gap, not
a hidden one, and not a spec defect — surface it; do not block. This rule applies
to every requirement kind (interface, subscription, addon), not just gRPC.

## Return to orchestrator

```
=== ENDPOINT DISCOVERY ===
## Candidate list
<keyed candidate list>

## Coverage matrix
<the matrix above>

=== SUMMARY ===
interfaces: <n_ok>/<n_required>  subscriptions: <n_ok>/<n_required>  addons: <n_ok>/<n_required>
NOT_TESTABLE: <comma-separated requirement names, or none>
```

Do NOT modify the candidate spec.

END-OF-AGENT-ENDPOINT-DISCOVERY-SENTINEL
