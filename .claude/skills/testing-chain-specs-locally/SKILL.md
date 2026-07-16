---
name: testing-chain-specs-locally
description: Use when asked to test, run, verify, or boot a lava-specs chain spec locally (a specs/*.json PR) with the smart-router binary, or to post a manual-run results comment on a spec PR.
---

# Testing Chain Specs Locally (smart-router)

Binary: `${SMARTROUTER_BIN:-../smart-router/build/smartrouter}` — a smart-router checkout next to this repo, overridable per machine via `SMARTROUTER_BIN` (e.g. in the gitignored `.claude/settings.local.json` `env` block). Repo: the current working directory (this repo's root); run all commands from there.

## Iron rule: all traffic goes THROUGH the router

Never curl/websocat a node directly — not for pre-flight probes, not to "prove a -32601 is a node gap". The router's boot verifications, relay logs, and `health` output ARE the evidence: a -32601 relayed through the router already came from the node. Direct pings are only acceptable if the user explicitly asks for them.

DNS lookups are NOT node traffic — `getent hosts <candidates>` is allowed and pays off: try the chain's host-naming pattern (`data.`/`archive.`/`testnet.` prefixes) to find tier hosts the pipeline missed. The resolved ELB/cluster name often reveals the tier (KAVA: `grpc.data.kava.io` → `...-archive-cluster-...` refuted the pipeline's "no archive-capable grpc host"). Also resolve ALL PR endpoints and **compare the IPs**: two hostnames on one IP = one origin (redundancy in name only — count it as ONE origin for polling, and expect benign `detected fork` tracker noise from backend tip-skew); a testnet A-record that includes a mainnet IP predicts vhost 502s from pool members without a testnet upstream (ASTAR: `evm.`=`rpc.astar.network` one IP; Shibuya's 3-IP pool contained that same IP → 502 waves). Nuance: mainnet+testnet sharing ALL IPs on a **CDN edge** (Cloudflare `2606:4700::/32`) is benign — SNI routing, no vhost-502 risk — but still count both nets as ONE origin for the polling budget (OASIS: both hostnames = the same 3 CF IPs; ran multiplier 1, zero 429s).

## Workflow

1. **Gather.** `gh pr view <n> --json body,comments` — endpoints, chain-ids, expected values, and prior probe tables live there; reuse them. Check auto-memory for a prior `<CHAIN> smartrouter run` (chain gotchas). Then sync the tree: `git fetch origin <branch>` and confirm `git log --oneline HEAD..origin/<branch>` is empty — spec pipelines push fix commits after the PR opens; a stale tree tests the wrong spec.

   **Field-cleanup guard.** Before boot, run the reintroduction guard on the spec file(s) the PR adds or modifies — smart-router removed 15 spec fields (spec-level governance, `proposal.title`/`description`, top-level `deposit`, api-level `extra_compute_units`/`category.local`/`category.subscription`) and a reintroduced one is a spec defect to report, not to test around:
   ```bash
   bash .claude/skills/create-spec/scripts/check_unused_fields.sh <chain>.json   # + any parent the PR touches
   ```
   Strict is the default — exit 1 on any removed field, printing its exact JSON path. Add `--warn` (reports but exits 0) ONLY when deliberately booting a known-legacy fixture that still carries the old fields, so it can still be exercised — never as an escape hatch for a live PR spec.

   While reading the Phase-8 comment, look for a "router-config note" saying the pruning **archive** verification was NOT_EXERCISED / `skip-verifications: [pruning]` was applied ("no gateway serves `{archive, websocket}` on one connection") — that's the docker harness being unable to express archive-tagged ws legs, NOT a real limitation. The 4-leg layout (step 2) exercises the verification for real; a green `verification=pruning verificationKey={Extension:archive}` boot line closes the pipeline's open item and belongs in the PR comment's headline (ASTAR refuted the claimed limitation; CODEX reconfirmed on both nets).

   **Family pre-flight** — known family-wide spec defects; check BEFORE boot #1, fix per-chain (never the base spec):
   - **cosmos w/ grpc:** the chain's own grpc collection must override `GET_BLOCKNUM` with `function_template: "{}"` — otherwise it inherits COSMOSSDK's empty template and the grpc tracker crash-loops (`GET_BLOCKNUM missing function template`) on both nets. Testnet inherits the override via imports (babylon/akash/kava precedent). Check:
     ```bash
     jq '[.proposal.specs[].api_collections[] | select(.collection_data.api_interface=="grpc")
          | .parse_directives[]? | select(.function_tag=="GET_BLOCKNUM")] | length' <chain>.json  # 0 = defect
     ```
   - **cosmos w/ archive:** archive pruning `expected_value` must be `"1"` (genesis=1, base-10) — `"0"`, hex, `"*"` all fail (cronos precedent).
   - **substrate w/ archive:** TWO valid pruning shapes — check what the verification's own `parse_directive` calls before "fixing" anything:
     ```bash
     jq -c '.proposal.specs[].api_collections[].verifications[]? | select(.name=="pruning")
            | {template: .parse_directive.function_template, values: [.values[].expected_value]}' <chain>.json
     ```
     (a) number-returning `GET_EARLIEST_BLOCK`: `expected_value` must be hex `"0x0"` not `"0"` (polkadot precedent). (b) preferred: dedicated `state_getRuntimeVersion`@historical-hash directive checking `specVersion` — its expected_value is a specVersion like `"3001"`, NOT `"0x0"`; healthy as-is, do not "fix" it (KUSAMA/POLYMESH/polkadot_asset_hub). DEFECT: pruning reusing a HASH-returning directive (`chain_getBlockHash(0)`) boot-blocks universally — signature `parsedResult=18446744073709551614` (hash mis-parsed as uint64) then `all static providers failed verification`; fix = rewrite as shape (b) with per-net hashes (a testnet node can't resolve a mainnet hash) — POLYMESH Phase-8 precedent.

   If a check fires you may boot once unfixed to capture the failure for the PR comment's before/after, then apply and re-boot.
2. **Config.** ONE file `config/<chain>.yml` in the repo covering mainnet AND testnet (separate `endpoints:` ports — pick the next free `:33xx`/`:77xx` pair: `grep -h 'listen-address' config/*.yml`). Header comment = the exact run + health commands and the reason for every flag. First interrogate the spec — its interfaces/addons/extensions dictate the legs (testnet entries often show empty: they inherit via `imports`, read the mainnet row):

   ```bash
   jq -c '.proposal.specs[] | {index, ifaces: ([.api_collections[].collection_data.api_interface]|unique),
     addons: ([.api_collections[].collection_data.add_on]|unique - [""]),
     exts: ([.api_collections[].extensions[]?.name]|unique)}' <chain>.json
   ```

   **WebSocket need = SUBSCRIBE directives, not a category flag.** Whether a spec needs a ws leg is decided by its `FUNCTION_TAG_SUBSCRIBE` parse directives (serialized `"function_tag": "SUBSCRIBE"`) — there is no `category.subscription` field to read. The api_interface that carries a SUBSCRIBE directive needs, in each of its provider blocks, either a `wss://` leg or `--skip-websocket-verification` (step 3), or chain-router creation for that interface fails. SUBSCRIBE almost always arrives **through `imports`**, so grepping the chain's own collections reads 0 for the very chains that need it: every EVM L2 inherits `eth_subscribe` (jsonrpc) from `ETH1`, and every cosmos chain inherits `subscribe` (tendermintrpc) from `TENDERMINT`, both with zero own directives (`BASE`→`imports:["ETH1"]`; `BASES`→`BASE`→`ETH1` is two hops), while substrate specs like `ASTAR` add their own jsonrpc `chain_subscribe*` on top. Own-count 0 is not "no subscriptions" — resolve the chain. `--use-static-spec "$PWD/"` loads the whole catalog, so slurp every file and close over imports (use the `index` from the interrogation above):
   ```bash
   jq -n --arg target "<INDEX>" '
     ([inputs.proposal.specs[]] | map({(.index): .}) | add) as $by
     | def sub($i): ($by[$i] // {}) as $s
         | (([$s.api_collections[]?.parse_directives[]? | select(.function_tag=="SUBSCRIBE")] | length) > 0)
           or (($s.imports // []) | any(sub(.)));
       {target: $target, needs_ws: sub($target)}' *.json
   ```
   A `true` carried on **jsonrpc** — EVM `eth_subscribe` or substrate `chain_subscribe*` — is what the "subscription chain" rules below assume: that block can't serve without a wss leg (a no-wss endpoint is unservable there), and on an archive chain it pulls in the https/wss 4-leg recipe (`config/astar.yml`, below). A `true` carried only on **cosmos tendermintrpc** (`subscribe` via TENDERMINT) is expected and implies neither — cosmos serves over https; confirm at boot whether that interface actually needs a ws leg or just `--skip-websocket-verification`. `false` → https-only, no ws leg needed.

   Copy the schema from `config/cronos.yml` (EVM, no public wss) — other references: `config/astar.yml` (**spec with subscriptions + real wss + archive** — the FLARE/BOB 4-leg recipe: main blocks = https/wss × {base, `addons:["archive"]`}, because subscriptions force a ws leg per serving block AND the pruning verification needs one `{archive+websocket}`-capable leg; gap addons START in https-only blocks — excluded at boot, itemized by `health`; do NOT give a FAILING gap block wss legs, the dial storm 429s the origin — MOONBEAM. But on a subscription chain that exclusion is transport-caused and proves nothing about capability — see the gap-addon promotion rule in step 5), `config/akash.yml` (cosmos rest/grpc/tendermintrpc), `config/concordium.yml` (grpc protoset), `config/stacks.yml` or `config/multiversx.yml` (rest-only gateway API), `config/mina.yml` (GraphQL-over-rest). Skeleton:

   ```yaml
   metrics-listen-address: "0.0.0.0:7779"
   endpoints:
     - listen-address: "0.0.0.0:3360"
       network-address: "0.0.0.0:3360"
       chain-id: "<MAINNET_ID>"
       api-interface: "jsonrpc"
     # testnet: same shape on :3361
   direct-rpc:
     - name: "<chain>-mainnet"
       chain-id: "<MAINNET_ID>"
       api-interface: "jsonrpc"
       node-urls:
         - url: "https://<node>"                 # base leg
         - url: "https://<node>"                 # archive is an EXTENSION —
           addons: ["archive"]                   #   its leg rides in the base block
         - url: "https://<node>"
           addons: ["txpool"]
     - name: "<chain>-mainnet-debug"             # gap-prone addons (debug/trace/
       chain-id: "<MAINNET_ID>"                  #   bundler) each get their OWN block:
       api-interface: "jsonrpc"                  #   a failing addon verification
       node-urls:                                #   excludes its whole provider block,
         - url: "https://<node>"                 #   so isolate it from base routing
           addons: ["debug"]
   ```
   One provider block per origin for base+archive+txpool = one chain tracker = one polling stream (avoids shared-origin 429). An alias hostname on the same origin (same IPs) rides as extra legs INSIDE that block, not as its own block — it still gets boot-verified per-URL but adds no second tracker (TEMPO: moderato legs in the testnet block).

   wss node-urls may need a **path suffix** — take it from the PR's Phase-8 notes (OASIS: `wss://sapphire.oasis.io/ws`; the root `/` is POST-only and 405s the upgrade). When the PR expects the archive verification to FAIL on the public node (earliest ≠ genesis), the archive legs go in their OWN block like a gap addon — base leg + archive leg, https-only — not in the main block (OKB/OASIS), so the expected exclusion doesn't take base routing down.

   A VERIFIED-WORKING addon block (Phase 8 shows its verification passing on the gateway) on a chain with the archive extension gets `https/wss × {addon, addon+archive}` legs, not just plain addon legs: old-block addon relays widen to `{addon:<name>, extensions:archive}` and addons hard-fail (`No Providers For Addon`) without a combined leg — the plain layout serves only near-tip addon calls (CODEX: `debug_getRawHeader["0x1"]` hard-failed on boot #1, served after the debug block gained `addons: ["debug", "archive"]` legs; LINEA saw the trace-on-old-block flavor). Presumed-gap addon blocks stay single-leg https-only as above.

   On a subscription chain, a PR endpoint with NO public wss can never serve through the router no matter how capable its RPC is — chain-router creation requires a ws leg in the block. Signature: the ws upgrade answers an HTTP **redirect** (302, then 301 on the router's automatic `/ws` retry) instead of a handshake — deterministic tier-gating, not flakiness (thirdweb `<chainid>.rpc.thirdweb.com` free tier). Don't retry-loop it and don't drop it either: strip the block to https-only (base + archive legs), keep it as a health-only block, and report ⚠️ "healthy over https incl. archive depth, unservable on a subscription chain (no wss)" with health's green rows as the evidence (CODEX).

   PR endpoints are the starting set, not a mandate: a leg that never passes boot verification across 2+ sessions (spanning a rate-limit cooldown) gets dropped — comment the reason in the config header and report it as a ❌ operational row in the PR table. Don't leave it in "for coverage": with `--set-relay-retry-limit 0` there is no failover retry, so a sick leg returns its 502 straight to the client (KAVA: pruning-tier `api/rpc/grpc.kava.io` dropped, mainnet served from the healthy `.data` archive cluster).

   Chain with NO public testnet (CI shows `TESTNET_VERIFY: SKIPPED`): still ship the testnet endpoints/provider blocks, pointed at the **mainnet** origin — this exercises the testnet spec's `imports`/merge, verifications, and addon inheritance end-to-end, which CI never did. Document the alias in the config header and report ✅ PASS-with-alias-caveat ("validates inheritance, not an independent network") — never as testnet coverage (ARWEAVE: ARWEAVET → arweave.net, chain-id `arweave.N.1` shared by design). **This only boots when the testnet chain-id equals mainnet's.** When they differ (DASH: `test` vs `main`), the alias leg hard-fails chain-id verification and would fatal a combined live boot — run it as a **deliberate expected-fail scratch boot** instead: the `verify failed expected and received are different … rawParsedBlock=<mainnet-id>, verification.Value:<testnet-id>` line IS the inheritance proof (import chain resolved, per-net override applied, parse worked). Keep the alias block in the canonical config for `health` only (health reports per-leg and never fatals); report ⚠️ untestable-as-a-network / ✅ inheritance-validated, expected_value still un-live-verified.

   An interface with NO public upstream on EITHER net — e.g. Sidecar-style rest collections on Polkadot-family chains, where the public `*-rpc.polkadot.io` hosts are raw jsonrpc (`GET /blocks/head` → 405) — gets NO endpoints/provider blocks in the config: pointing its endpoint at the wrong-protocol node just hard-fails the chain-id verification and fatals the whole boot (one dead net/endpoint fatals the process — step 3). Report the interface ⚠️ untestable citing the pipeline's probe evidence; "needs any standard <server> deployment" is the PR recommendation (KUSAMAASSETHUB, POLKADOT: no public Substrate API Sidecar exists).

   rest upstream URLs are built by raw concatenation `<node-url><relay-path>`: directive traffic appends the bare `api_name` with **no separator**; client relays append `/<name>` and re-anchor any query string at the end. For GraphQL-over-rest chains (one `/graphql` endpoint, operation-per-api spec) end the node url in `graphql?` so appended names land in the query string, which GraphQL servers ignore (see `config/mina.yml`).
3. **Boot.**
   ```bash
   cd "$(git rev-parse --show-toplevel)"
   OTEL_SDK_DISABLED=TRUE "${SMARTROUTER_BIN:-../smart-router/build/smartrouter}" \
     config/<chain>.yml --use-static-spec "$PWD/" [flags]
   ```
   Boot in the background with output redirected to a scratchpad file (`> boot.log 2>&1`) — and point every watcher/grep at THAT file: the harness's own task-output file stays empty when you redirect, so a watcher on it hangs forever (NEOX).

   Situational flags: `--skip-websocket-verification` (spec has ws apis but no public wss), `--chain-tracker-polling-multiplier 1` (fast blocks / shared-origin rate limits / large `block_distance_for_finalized_data` on a shallow-retention public node — the tracker's init backfill of that window storms the origin), `--min-relay-timeout 15s` (slow or cold-starting gateways; the `health` subcommand does NOT accept it), `--set-relay-retry-limit 0` (rpm-capped gateways, else epoch re-verify demotes the sole provider — but it also disables failover: a relay landing on a sick leg returns that leg's error to the client, so sick legs must be removed from config, not left in rotation). Watch boot logs: every leg's verifications green, or the exclusion explained.

   Boot log signatures — grep, don't eyeball: success = `ChainTracker initialization complete ... failed=0`, one line per interface × net (cosmos 3-iface dual-net = 6); fatal = `all static providers failed verification — cannot serve endpoint` (router exits non-zero); benign = `websocket is not provided in 'supported' map` on https-only tracker URLs when the block's wss legs exist (per-URL tracker routers warn individually). More benign signatures: `could not get block data in Chain Tracker ... GET_BLOCK_BY_NUM failed` WRNs that stop within ~2 retries per fresh tip block (gateway's height source ticks seconds before the block is servable — self-heals; persistent per-block repeats = real problem); `Rest reply is not in JSON format` ERRs when relaying plain-text/HTML error bodies from dead routes (the relay still returns them to the client); `invalid supported to check ... supported=archive` on specs that declare no archive (router-internal capability probe).

   When mainnet and testnet share a host, one net's tracker init storm can starve the other net's boot verification: a context-deadline on only one net — especially one CI verified recently — means try `--chain-tracker-polling-multiplier 1` + `--min-relay-timeout 15s` before blaming the endpoint.

   **One dead net fatals the WHOLE process** — the ASTART 502 storm exited the router while ASTAR was mid-validation, holding mainnet evidence hostage. If boot #1 fatals on one net's providers: keep `config/<chain>.yml` as the canonical artifact, generate per-net scratch copies (second copy on metrics port 7780; scratch copies MUST live inside a router config search path — `config/<chain>-<net>.scratch.yml` — the binary resolves its positional config only against the repo root, `repo/config/`, and `~/.lava`, and errors "no config file found" on an absolute scratchpad path — DASH), boot the healthy net normally, and wrap the flaky net in a retry-loop boot — start, watch ~90s for `ChainTracker initialization complete`, kill by PID and retry (≤8 attempts, 60s apart). Degraded pools flap on minute timescales: Shibuya fataled the combined boot, then verified 100% green on the next attempt.

   More benign signatures for the list above: `Expect block number from id: BlockId::Number(N)` parse WRN/ERRs (Frontier chains — an LB backend lagging the tip when the tracker asks for a just-minted block; self-heals ≤2 retries, same class as the GET_BLOCK_BY_NUM note); `endpoint ChainTracker detected fork` when one origin's https vs wss backends skew by a block (see the DNS same-IP check); `invalid adaptive sync bounds, using defaults p10=NaN p90=NaN` (startup, before enough samples); `provider data not found, using default address=wss://…` and `WebSocket pool: scaled up` during client ws sessions (POLYMESH/TEMPO); repeating `chain tracker creation error ... GET_BLOCKNUM failed to parse response` on a `wss://` NodeUrl + `rpc method is not whitelisted` blockParsing ERRs, session-long — the ws gateway's method whitelist blocks `eth_blockNumber` while https allows it, so the per-URL ws tracker never seeds; benign iff the block's init line says `failed=0` (RACE: ~110 lines/13 min, https bucket carried the tracker).
4. **Relays.** 2–3 requests per surface — every interface and every addon/extension, both networks — against the router's listen ports. After each, check router logs to confirm success and routing (e.g. `extensions=archive` actually served the old-block query). Run staged relay scripts with output redirected to a file — piping through `head`/`head -c` for display SIGPIPEs the script mid-matrix and silently truncates the run (looks like results, isn't).
   - Resolve live relay inputs (addresses, tx/block hashes, token ids) through the router itself — e.g. tip/pool query → follow-up relays on what it returned. Direct curls for input-resolution violate the iron rule and got the Phase-8 pipelines Cloudflare-429'd. Quiet EVM chains (mostly-empty blocks): don't scan recent blocks tx-by-tx — sweep `eth_getLogs` over ~100-block windows stepping back from tip and take a `transactionHash` from the first non-empty window (OASIS: a 15-block scan found nothing; the first log-window round found a tx). On rollups with system txs (OP-Stack: the L1-attributes deposit tx), skip the sweep — every block's `transactions[]` from `eth_getBlockByNumber(latest)` has ≥1 hash for free, and getLogs misses log-less activity entirely (RACE: 5000 blocks of deposit txs, zero logs).
   - Substrate jsonrpc: fire archive with a numeric-height `PARSE_BY_ARG` api — `archive_v1_hashByHeight [1000]` (POLYMESH); hash-param apis (`chain_getBlock`, `archive_v1_body`) don't distance-parse, so they never fire it. On specs with a state-based pruning check, add the free self-consistency relay: `chain_getBlockHash [<pruning-block-number>]` through the router must return exactly the hash baked into the pruning directive — catches a wrong-hash/wrong-net paste per net. When the directive only carries a hash (specVersion shape), derive the number first: `chain_getHeader [<hash>]` → `.result.number` → `chain_getBlockHash [<number>]` must round-trip to the same hash (KUSAMAASSETHUB: exact on both nets). Cleanest human-readable archive-state proof — and a live verifier for hash-index `PARSE_BY_ARG` on `*At` methods: `state_getStorageAt ["0xf0c365c3cf59d671eb72da0e7a4113c49f1f0515f462cdcf84e0f1d6045dfcbb", <old-hash>]` (Timestamp::Now, LE u64 ms) — decoding to an old date proves historical-state access end-to-end.
   - Params-validated methods (address/tx-taking): a node-originated `-32602` relayed verbatim through the router is PASS-existence evidence (the pipeline's classification; POLYMESH `system_accountNextIndex` → `"Base 58 requirement is violated"`). No need to hunt a real input unless the method's parsing/routing is itself under test. When it IS under test (a watch-list item on a method's param shape or block-arg index), the -32602 error TEXT is the schema oracle: iterate the param shape off successive node errors until the call passes, then re-fire with an old block to prove the parser index end-to-end (TEMPO `eth_getStorageValues`: `"expected a map"` → `[{addr:[slots]}, blockTag]`, and the `0x1` variant fired `extensions=archive` — closed the reviewer's M1 with live evidence).
   - EVM filter APIs behind a shared edge/LB are a state lottery: `eth_newBlockFilter` succeeds but an immediate `eth_getFilterChanges` on that id returns `-32602 filter not found` — filter state is per-backend and relays aren't sticky (TEMPO, both nets). Existence/routing PASS; report as an operational note (consumers should prefer ws subscriptions or a dedicated node), never as a method failure.
   - REST-family specs (beacon/cardano/tezos/multiversx pattern) block-parse everything as `DEFAULT ["latest"]`, so distance-based archive routing never fires — an old-block relay shows `extensions=` empty and still succeeds on a base leg. Exercise the extension with a `lava-extension: <name>` request header and confirm `extensions=<name>` in the `Choosing providers` log line. The header is silently dropped when no leg serves that extension. Exception: tendermintrpc `block` is params-parsed, so an old-height relay auto-fires `extensions=archive` with NO header — that's the expected evidence there.
   - **Extensions soft-fallback; addons hard-fail.** On jsonrpc chains an old-block relay fires `extensions=archive`, but if no archive-capable leg exists the router logs `NO VALID PROVIDERS - TRIGGERING RESET` and re-chooses with `extensions=` empty — the relay SUCCEEDS on a base leg as long as the pruned node still retains the block (OASIS). A successful old-block relay is therefore proof of NOTHING by itself — not that archive works, not that routing broke: grep the relay's GUID for the `extensions=archive` → reset → empty re-choose sequence. Addon calls have no fallback — they hard-fail `No Providers For Addon`; but their hard-fail path ALSO emits `NO VALID PROVIDERS - TRIGGERING RESET` pairs first (with `addon=<name>` and empty `extensions=`) — when counting resets to detect the archive fallback, filter by GUID or the excluded-addon relays pollute the count (DASH: 6 resets, all addon GUIDs, zero archive). Report the fallback as an operational note: near the retention edge it becomes a provider lottery.
   - On rest, evidence = HTTP status + body relayed through the router. A 404 body from a capability-split origin is a *valid response* — no failover, the client sees a provider lottery on that path. Classify as public-node gap, not spec defect.
   - **Gateway-gated ≠ node gap** — before writing "node lacks it", check whether the capability's methods ever passed elsewhere (earlier pipeline runs, pre-fix collections). A gateway that 405s/blocks specific methods in front of a capable node is a third flavor (DASH: GetBlock 405s `getindexinfo` so all 3 addressindex gating verifications fail, yet the index methods themselves PASSed in Phase 8 — the node runs the indexes). The distinction changes the PR recommendation: "any dedicated node closes this" vs "needs a special node build/flag".
   - One timeout is not a classification — retry once before calling a method dead. Some gateways cold-start each new path (>15s first hit, instant after). Retry on a second axis too: **input class, not just input freshness** — before classifying a deterministic route dead, ask whether the input kind is right (data-bearing tx vs bare transfer, indexed vs unindexed item) and resolve an alternate-class input through another surface of the router (ARWEAVE: `/{id}` "failed" on two fresh transfer txs, PASSed on a Content-Type-tagged data tx found via router graphql; Phase 8 made the same input-artifact error on `/block/hash/{hash}`).
   - A pipeline-reported reproducible `-32000 context deadline exceeded` WARN on a large-payload method is a one-flag experiment, not a settled gap: re-fire it with the router running `--min-relay-timeout 15s`. PASS under the flag = router default-timeout artifact — report ✅ with an operational note (providers should set a relay-timeout floor for the chain); still deadlines = genuine upstream hang, ❌ public-node gap (KUSAMAASSETHUB: `state_getStorage(:code)`@latest returned 4.6MB in 6s under the flag, while `state_trieMigrationStatus` still deadlined twice). Either way the manual run converts the pipeline's WARN into a classification.
   - After the relay pass, verify relays **bound to spec apis**: `curl -s localhost:7779/metrics | grep -oE 'function="[^"]*"' | sort -u`. Any `Default-`-prefixed label means that path matched no spec api and ran on the router's default container (CU 20, no `timeout_ms`, DEFAULT/latest parsing) — a spec defect (api name vs request path mismatch) that PASS counts can't see, because the fallback still relays.
   - Labels alone aren't enough when the spec has a catch-all api (`/{id}`-style): **diff the set of paths you probed against the emitted labels**. A probed api missing its own label bound to a sibling pattern — and the winner is a per-request coin flip (Go-map iteration in the rest matcher), so one sample lies: re-fire the path 2–3× and diff `rpc_endpoint_total_relays_serviced` counters to confirm (ARWEAVE: `/info`/`/height`/`/total_supply` randomly absorbed by `/{id}`; `/tx_anchor` lost one request, won the next; `/tx/pending` → `/tx/{id}`). Responses stay correct (path relayed verbatim) — impact is CU/category attribution only; report as router-matcher finding, not a spec defect.
   - **Run ws subscription tests LAST**, after all HTTP evidence and a metrics snapshot: the router can crash on client ws disconnect (ConsumerWebsocketManager / DirectWSSubscriptionManager teardown family — reproduced on PR-40 Phase 8, MOONBEAM, ASTAR). Never probe `*_submitAndWatch`-style methods with placeholder payloads (known SIGSEGV, and real payloads would broadcast). One crash instance = a reportable router finding, not a reason to redo the run. Use python `websockets` (wscat emits nothing non-interactively); the router's client-facing ws endpoint is `/ws` — root `/` answers 405 to upgrades. On substrate-style pub/sub expect: sub id returned, zero pushes forwarded, unsubscribe → -32601 from the router's in-session dispatcher (only the `eth_subscribe` pattern is special-cased; `Unsolicited RPC response` WRNs corroborate) — router capability gap, not a spec defect. On EVM chains the special-casing covers pushes only — `eth_unsubscribe` is relayed upstream, so a gateway that whitelists subscribe but not unsubscribe ends a working subscription with a `-32601` unsubscribe reply (RACE, both nets): node gap, expected shape.
   - If the PR's pipeline comments carry a watch-list (W1…), re-verify each item through the router — confirming or refuting those is the highest-value content of the manual run.
5. **Health.** Stop the router first (shared-origin rate limits), then:
   ```bash
   OTEL_SDK_DISABLED=TRUE "${SMARTROUTER_BIN:-../smart-router/build/smartrouter}" health config/<chain>.yml \
     --use-static-spec "$PWD/" [--skip-websocket-verification]
   ```
   Compare with the live run: each leg's `ok`/`error` must mirror boot behavior. State the agreement (or divergence) explicitly in the PR comment. Agreement is at the verdict level, not the error-string level: one gateway can gate the same methods in two flavors — HTTP `403 Forbidden` to health's addon verifications vs JSON `-32601` to live probes (RACE) — both are the same public-node gap, not a health/live divergence. Three health caveats: it accepts only a subset of run flags (`--min-relay-timeout` is rejected — a chain that needed it live will look degraded; say so rather than chase it); run immediately after a session it can context-deadline on a healthy origin — cool down 1–2 min and retry once before reporting divergence (5 min if the origin rate-limits — see below); and on **subscription chains**, check which connector type health actually opened before classifying ws-leg failures — the behavior is build-dependent. Old builds (pre-2026-07-07 fixes) open HTTP-only connectors even for `wss://` URLs (log: `Created HTTP connector`), so every verification carrying the subscription-forced `websocket` extension reports `connector is closed` for ALL ws-bearing legs — deterministic and cooldown-immune (ASTAR: two runs 10 min apart identical); there, cite the live boot as authoritative. Current builds open REAL ws connectors and ws legs verify green (NEOX: 16/16 incl. `{archive+websocket}` legs) — there a ws-leg failure is a REAL finding, not "the known limitation"; don't wave it off. Signature check for the old behavior: `Created HTTP connector` logged for a wss URL + the same URL verifying green over https in the SAME report. The https-only gap legs are where health earns its keep: addon verification -32601 alongside green chain-id/pruning/trustless-rpc on the same leg is the cleanest node-gap proof (the live boot never reaches gap-block addon verifications when the spec has subscriptions). Health is also the ONLY artifact that itemizes multi-verification addon failures: the live boot fail-fasts a provider block on its first failing verification, while health evaluates every verification on the leg individually — for an addon gated by several ANDed verifications, health is the sole evidence each one fires (DASH: 3× getindexinfo checks, each shown failing 405 separately).

   **Gap-addon promotion.** On a subscription chain the live boot excludes every https-only addon block at chain-router CREATION (`websocket is not provided in 'supported' map`; the 3-min retry goroutine then logs `retry: static provider chain router creation still failing`) — the addon verification never runs, so boot exclusion is transport-caused and is NOT capability evidence. Health is the classifier. A presumed-gap addon whose health verifications come back GREEN gets promoted: give its block https+wss legs (both tagged with the addon; on an archive chain add the `{addon+archive}` combined legs too — step 2), re-boot, relay the addon live and confirm `Choosing providers addon=<name>` chose the addon block, ship the ws-bearing layout in the canonical config, report ✅ PASS as new coverage (TEMPO: debug `debug_getRawHeader` + trace `trace_block`/pruning verified green in health and served full traces after promotion, while txpool stayed a genuine 403 gap). The MOONBEAM no-wss-on-gap-blocks rule protects FAILING blocks from dial storms; a health-green addon block with wss legs boots clean.

   A WHOLESALE health failure — every leg on every net, errors reading `Post "https://…": dial tcp: lookup <host> on 127.0.0.53:53: server misbehaving` — is LOCAL systemd-resolved DNS, not the origin and not the rate-limiter playbook: nothing ever left the machine, so no cooldown is owed. `getent hosts` to confirm recovery, re-run immediately (TEMPO).

   Top-level `ok:false` is EXPECTED whenever the config carries expected-fail gap legs — the pass criterion is per-leg agreement with the live run, not the top-level flag (OASIS: exit 0, `ok:false`, serving legs 4/4 green, 8 gap legs failing for the documented node reasons).

   The report is the LAST pretty-printed JSON object after a stream of JSON log lines. Schema: top-level `{ok, error, results[]}`; each leg in `results[]` has `chainId, name (provider block), url, transport (http/ws), addons[], extensions[], ok, latestBlock, verifications[] {name, addon, extension, ok, error}`. Slice + tabulate (the PR comment wants "N/N legs ok"):
   ```bash
   tail -n +"$(awk '/^{$/{n=NR} END{print n}' health.log)" health.log > health.json
   jq -r '.results[] | [.chainId, .name, .url, .transport, ((.addons//[])|join(",")),
     ((.extensions//[])|join(",")), (if .ok then "OK" else "FAIL" end),
     ([.verifications[]? | select(.ok|not) | "\(.name)[\(.addon//"")\(.extension//"")]: \(.error//""|.[0:80])"]|join(" ;; "))
   ] | @tsv' health.json
   ```
6. **PR comment.** Draft in the format below; post with `gh pr comment` (confirm with the user first unless they already asked for the comment).
7. **Memory.** Save/update the `<CHAIN> smartrouter run` memory with the gotchas found.

## Rate-limited origins (the boot itself trips the limiter)

Symptoms: after a session (or a CI pipeline run) against the same origin, EVERYTHING fails at once — HTTP 420/429 bodies (`RequestRateLimitExceeded`), wss handshake 420, grpc reflection `Internal: server closed the stream`, then 502s — and a reboot fatals with `all static providers failed verification`. This impersonates a total outage; it's a per-IP limiter whose budget one full boot-verification pass roughly exhausts (KAVA: the pipeline's "mainnet outage" was this).

Playbook:
- Flags: `--chain-tracker-polling-multiplier 1 --set-relay-retry-limit 0 --min-relay-timeout 15s` (gentlest polling, no retry storms, outlast throttled responses).
- **5-min cooldown between router sessions** against the origin. 90s is not enough; a reboot inside the window wastes the attempt AND deepens the block.
- **Stage the relay matrix as a script BEFORE booting, fire it the moment trackers complete.** Tracker polling consumes the budget as the session ages — a relay that succeeds at second 10 gets 420'd at minute 2. One burst right after boot beats spaced-out batches.
- Boot verification + tracker streaming already ARE through-router evidence for a leg (chain-id/pruning/tx-indexing verified, GET_BLOCKNUM/GET_BLOCK_BY_NUM exercised every poll) — if the burst window still misses a surface, say so and lean on that rather than hammering.
- Mainnet and testnet limiters are usually independent — run the testnet matrix while mainnet cools.
- health: same 5-min cooldown after stopping the router, or it lies.
- PR comment: report the limiter itself as an operational finding (providers need dedicated nodes; public endpoints sustain only light traffic).

## Degraded load-balanced pools (the 502 lottery)

Distinct from a rate limiter: sick pool members answer nginx 502 in waves **regardless of your traffic** — cooldowns don't help, retries do. Tell them apart: a limiter fails everything at once right after a session (420/429 bodies); a degraded pool fails a random fraction continuously, and DNS shows multiple A-records (ASTAR/Shibuya: 3 IPs, one of them the mainnet box).

Client-visible error shapes through the router — classify before reacting:

| Error (through router) | Meaning | Action |
|---|---|---|
| relayed `HTTP 502 ... (HTTP 502 from provider)` | relay landed on a sick backend; sole provider = no failover | retry the relay — 2–8 tries is normal on a degraded pool |
| `No pairings available` | the sole provider got demoted after upstream-failure bursts | wait for background revalidation (~3 min), retry; NOT a method failure — never classify a method on this error |
| `No Providers For Addon` | gap-block exclusion working as designed | expected; stop retrying |

Playbook: retry-loop boot (step 3), a per-relay retry wrapper keyed on the two retryable shapes above, ws relays may lose the lottery at upstream-dial time even though boot-time wss verified (report both facts). Report the net as ✅ PASS with a lottery caveat plus an operational row: providers need a dedicated node; the public pool is only a smoke reference. The tracker may also crash-loop mid-storm (`ChainTracker startup failed; retrying`) — endpoint health, not spec.

## PR comment format

Fixed structure, adapt contents (omit "Spec fix" if none):

```markdown
## Manual smart-router run — interfaces & addons (YYYY-MM-DD)

<1 paragraph: booted both specs via the smart-router binary (`--use-static-spec`,
single local config for both nets: `config/<chain>.yml`) against the PR's endpoints
<urls>, exercised every interface/addon through the router, cross-checked with
`smartrouter health`.>

### Results (<scope note, e.g. "identical on X and XT; live run and `health` agree">)

| Surface | Result | Evidence (via router) |
|---|---|---|
| <iface> base | ✅ PASS | <verifications + sample relays with returned values> |
| <addon> | ❌ public-node gap | <method> → -32601 on both nets; router correctly excludes the provider at boot. Needs a <addon>-enabled node — not a spec defect |
| <ws surface> | ⚠️ untestable | <why, e.g. no public websocket → ran with --skip-websocket-verification> |

### Spec fix shipped in this run

`<commit>` — <what changed, why, observed effect before/after>.

### Run notes (operational, not spec issues)

- <flag choices + why, provider-block layout, residual log noise and why it's benign>
- `health` exit 0 and mirrors the live boot: <one line>.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Result legend: ✅ PASS · ❌ public-node gap (spec fine, node lacks it) · ❌ gateway artifact (node capable, gateway blocks the method/verification — say which evidence proves the node side) · ⚠️ untestable (say why).

## Common mistakes

| Mistake | Reality |
|---|---|
| curl the node directly "to prove it's a node gap" | The router log -32601 (jsonrpc) / relayed HTTP status+body (rest) + `health` `ok:false` IS the proof. Don't ping nodes. |
| Flagging an odd spec pattern (e.g. `DEFAULT ["latest"]` block_parsing on block-fetch APIs) as a defect | Grep the shipped gold specs of the same family first (beacon/cardano/tezos for REST) — it's usually the convention. |
| All addons on one node-url leg | One failing addon verification excludes the whole provider block — base dies with it. Isolate debug/trace/bundler. |
| Inventing flags (`--spec-path`, `--config`, `--polling-multiplier`) | Config file is positional; specs come from `--use-static-spec`; the multiplier flag is `--chain-tracker-polling-multiplier`. |
| Skipping `OTEL_SDK_DISABLED=TRUE` | Logs drown in OTEL export noise. |
| Running `health` while the router is up | Both hammer the same origin → 429s make health lie. Stop the router, cool down, then health. |
| Hardcoding endpoints/expected values from memory | The PR description + comments are the source of truth — `gh pr view` first. |
| Treating relay/probe PASS counts as proof the api catalog works | Unmatched rest paths silently degrade to the `Default-*` api and still relay. Only the `:7779/metrics` `function=` labels prove binding — and with a catch-all api in the spec, diff labels against probed paths too (shadowing is per-request random). |
| Classifying a method dead on one timeout | Cold gateways take >15s on the first hit of each new path. Retry once; only a repeated failure classifies. |
| Calling "outage" when every leg of an origin fails at once right after a session | That's a per-IP rate limiter (420/429/wss-handshake/reflection errors together). Cool down 5 min and follow the rate-limited-origins playbook before blaming the endpoint. |
| Keeping a persistently-failing PR endpoint in the config "for coverage" | With `--set-relay-retry-limit 0` there's no failover — clients get its 502s. Drop it, comment why, report as ❌ operational. |
| Cooldown-retrying `health` because ws-bearing legs say `connector is closed {extensions:websocket}` | On OLD builds only: deterministic HTTP-only-connector limitation — diff against the same report's https-only legs; live boot is authoritative. Confirm first via `Created HTTP connector` logged for the wss URL; current builds open real ws connectors (NEOX 16/16 green incl. archive+ws), where a ws-leg failure is a real finding. |
| Treating `No pairings available` as a dead method | It's provider demotion after upstream-failure bursts; revalidates in ~3 min. Only node-originated errors classify a method. |
| Reading a SUCCESSFUL old-block relay as "archive works" (or "routing broke") | Extensions soft-fallback: `extensions=archive` fires, 0 supporting legs → reset → a base leg serves it while the block is still in the pruned node's window (OASIS). Grep the GUID for the fallback sequence; only addons hard-fail. |
| Displaying relay-script output via `\| head -c` | SIGPIPE kills the script mid-matrix — the missing sections look like results. Redirect to a file, `head` the file. |
| `pkill -f 'smartrouter config/...'` — in ANY Bash tool call, foreground included | The harness runs commands via a shell whose own cmdline contains the pattern text, so pkill matches and kills its parent shell (exit 144) even as a standalone foreground command. Use `pkill -x smartrouter`, the bracket trick (`pkill -f 'smartrouter [c]onfig/...'`), or kill by PID. |
| Foreground `sleep` for boot-watches or cooldowns — even chained (`sleep 45; grep ...`) | The harness blocks foreground sleep. Run every wait as a background until-loop (`run_in_background`: `until grep -q <signature> <log>; do sleep 2; done`) — always with an iteration cap. |
| Chaining a background waiter on another background task's output file (cooldown task → health task) | A wedged sleep task never writes its file and the watcher hangs forever (OASIS). Cooldowns gate on WALL CLOCK in one self-contained loop: compute the deadline at router-kill time and embed it literally — `until [ $(date +%s) -ge <kill_ts+300> ]; do sleep 5; done` — then run health in the same command. |
| Classifying an addon as a node/gateway gap because its https-only block was excluded at boot (subscription chain) | The block failed chain-router creation on the missing ws leg — its addon verification never ran. Health classifies; if green, promote the block with wss legs and relay live (TEMPO: debug/trace served; only txpool was a real 403 gap). |
| Treating a wholesale `health` failure (every leg, every net) as an origin outage or limiter | Read the error first: `lookup <host> on 127.0.0.53:53: server misbehaving` = LOCAL systemd-resolved DNS — nothing reached the origin, no cooldown owed. `getent hosts`, re-run immediately (TEMPO). |
| Giving a verified-working addon block only plain addon-tagged legs (archive chain) | Old-block addon calls widen to `{addon, archive}` and hard-fail `No Providers For Addon` — addons never soft-fallback. Working addon blocks need `https/wss × {addon, addon+archive}` legs (CODEX debug). |
| Treating a wss upgrade answering 302/301 as a flaky handshake (retry it) or as grounds to drop the endpoint | An HTTP redirect to the upgrade = no ws endpoint exists (tier-gating, e.g. thirdweb). On a subscription chain that block can never serve: strip to https-only, keep for `health`, report ⚠️ unservable-no-wss (CODEX). |
