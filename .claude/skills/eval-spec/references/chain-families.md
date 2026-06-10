# Chain Families for Eval Batches

## Chain Pool

Chains are organized by protocol family, each mapped to a JSON specification file in the [Magma-Devs/lava-specs](https://github.com/Magma-Devs/lava-specs) repository. These families represent distinct blockchain execution models and architectures.

### EVM (18 chains)

Ethereum Virtual Machine-based chains. Support standard Ethereum RPC methods, with some offering protocol-specific extensions (e.g., debug, trace, bundler APIs).

| Chain | Spec File | Notes |
|-------|-----------|-------|
| ethereum | ethereum.json | Reference EVM. Has debug, trace, bundler add-ons. |
| arbitrum | arbitrum.json | L2 rollup (Arbitrum One) |
| optimism | optimism.json | L2 rollup (Optimism OP Mainnet) |
| base | base.json | L2 rollup (Coinbase Base) |
| polygon | polygon.json | Sidechain (Proof of Stake) |
| bsc | bsc.json | BNB Smart Chain |
| avalanche | avalanche.json | Multi-chain platform (C-Chain is EVM) |
| blast | blast.json | L2 rollup with yield |
| zksync | zksync.json | Zero-knowledge rollup |
| scroll | scroll.json | Zero-knowledge rollup |
| fantom | fantom.json | DAG-based EVM |
| sonic | sonic.json | Fantom successor |
| manta_pacific | manta_pacific.json | L2 rollup |
| mantle | mantle.json | L2 rollup |
| worldchain | worldchain.json | L2 rollup (World Chain) |
| celo | celo.json | Mobile-focused EVM |
| fuse | fuse.json | EVM sidechain |
| bera | bera.json | Berachain |

### UTXO (4 chains)

Unspent Transaction Output model chains. Use transaction inputs/outputs and script-based programming (Script language).

| Chain | Spec File | Notes |
|-------|-----------|-------|
| btc | btc.json | Reference UTXO chain (Bitcoin) |
| bch | bch.json | Bitcoin Cash |
| doge | doge.json | Dogecoin |
| litecoin | litecoin.json | Litecoin |

### Cosmos (11 chains)

Cosmos SDK-based chains. Share modular architecture and Inter-Blockchain Communication (IBC) protocols. Some import additional modules like CosmWasm or CosmosSDK 5.0.

| Chain | Spec File | Notes |
|-------|-----------|-------|
| cosmoshub | cosmoshub.json | Reference Cosmos hub. Imports COSMOSSDK50 + COSMOSWASM. |
| osmosis | osmosis.json | Automated Market Maker (DEX) chain |
| stargaze | stargaze.json | NFT chain |
| juno | juno.json | Smart contract (CosmWasm) chain |
| celestia | celestia.json | Data availability layer |
| stride | stride.json | Liquid staking protocol |
| axelar | axelar.json | Cross-chain communication |
| elys | elys.json | DeFi protocol |
| secret | secret.json | Privacy-preserving chain |
| side | side.json | Side protocol |
| union | union.json | ZK interoperability bridge |

### Standalone (16 chains)

Chains with unique execution models and consensus mechanisms that don't fit standard families.

| Chain | Spec File | Notes |
|-------|-----------|-------|
| solana | solana.json | Parallel execution VM with Proof of History |
| near | near.json | Sharded architecture, WebAssembly VM |
| aptos | aptos.json | Move language VM |
| sui | sui.json | Move language variant with object-centric model |
| ton | ton.json | Telegram Open Network |
| starknet | starknet.json | ZK-STARK L2 with Cairo VM |
| stellar | stellar.json | REST-only interface, consensus algorithm |
| cardano | cardano.json | Extended UTXO model, Haskell-based |
| ripple | ripple.json | XRP Ledger, custom consensus |
| hedera | hedera.json | Hashgraph consensus |
| filecoin | filecoin.json | Storage network, Proof of Replication |
| tron | tron.json | EVM-compatible but distinct architecture |
| hyperliquid | hyperliquid.json | L1 optimized for perpetual futures |
| fuel | fuel.json | Modular execution layer |
| movement | movement.json | Move language VM |
| namada | namada.json | Privacy-focused, Cosmos SDK-based |

## Batch Selection Rules

### Per-Batch Constraints

Each evaluation batch is composed of **exactly 7 chains** with the following distribution:

- **Minimum 1 EVM** — at least one chain from the EVM family
- **Minimum 1 UTXO** — at least one chain from the UTXO family
- **Minimum 1 Cosmos** — at least one chain from the Cosmos family
- **Remaining 4 slots** — any family (repeats allowed)
- **No duplicates** — each chain appears at most once per batch

### Cross-Batch Diversity

To maximize coverage and avoid redundant testing:

- **Track tested chains** across all completed batches
- **Prefer untested chains** when selecting for each batch slot
- **After exhaustion** — once all chains in a family have been tested at least once, allow repeats from that family
- **Optimize coverage** — prioritize families with fewer tested chains

### Selection Algorithm

Execute the following steps in order for each batch:

1. **Pick 1 EVM** — select a random untested EVM chain (fall back to random if all tested)
2. **Pick 1 UTXO** — select a random untested UTXO chain (fall back to random if all tested)
3. **Pick 1 Cosmos** — select a random untested Cosmos chain (fall back to random if all tested)
4. **Pick 4 more** — select 4 random untested chains from any family
5. **Ensure uniqueness** — verify all 7 selections are distinct (no duplicates)
6. **Mark as tested** — record all 7 chains as tested for batch tracking
