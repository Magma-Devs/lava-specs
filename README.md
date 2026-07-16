# Lava Specs

Chain specifications for the [Lava Network](https://www.lavanet.xyz/). Each `<chain>.json` at the repo root defines the APIs a provider commits to serving for one blockchain (mainnet + testnet entries), used to onboard that chain to Lava.

## Spec shape (field contract)

Every `<chain>.json` is exactly one canonical proposal envelope — nothing else at the top level:

```json
{ "proposal": { "specs": [ /* mainnet entry, testnet entry */ ] } }
```

No `proposal.title`, no `proposal.description`, no top-level `deposit`. smart-router [#218](https://github.com/Magma-Devs/smart-router/pull/218) removed 15 spec fields the router never read; specs must not carry any of them:

- **Spec-level (governance):** `min_stake_provider`, `providers_types`, `contributor`, `contributor_percentage`, `shares`, `identity`, `block_last_updated`, `reliability_threshold`, `data_reliability_enabled`
- **Proposal envelope:** `proposal.title`, `proposal.description`, top-level `deposit`
- **API-level:** `extra_compute_units`, `category.local`, `category.subscription`

Two consequences for authoring:

- **`compute_units` is the only CU input** — `extra_compute_units` is gone.
- **A method is a subscription iff it carries a `FUNCTION_TAG_SUBSCRIBE` parse directive** — never via `category.subscription`.

A reintroduction guard enforces the contract. Run it on any spec:

```
bash .claude/skills/create-spec/scripts/check_unused_fields.sh <chain>.json
```

Strict mode (the default) exits non-zero and prints the JSON path of every removed field it finds; pass `--warn` only when deliberately exercising a legacy fixture. Both CI workflows run this guard as a hard gate, so a generated or committed spec that carries any removed field fails the run (and, where branch protection requires the check, is blocked from merging).

## Skill-assisted workflow

The repo ships Claude Code skills (slash commands) to build, audit, tune, and test these specs.

Four skills build and maintain chain specs. Each is a slash command in Claude Code.

| Command | Does | Output |
|---|---|---|
| `/create-spec` | Onboards a new chain: research → synthesize → validate → boot/probe → review. 12-phase pipeline. | `<chain>.json` at repo root |
| `/review-spec` | Audits an existing spec: params, API coverage, block parsing, parse directives. | review report (no edits) |
| `/testing-chain-specs-locally` | Boots a spec PR through the local smart-router binary against real endpoints; reports PASS/FAIL per interface. | run verdict + optional PR comment |
| `/eval-spec` | Tunes `/create-spec` itself: generates a batch, scores vs ground truth, edits the skill, loops. | tuned `create-spec/` + scores |

## Normal workflow

```
/create-spec        # build the spec
/review-spec <chain>.json [api-docs] [credentials]   # audit it
# apply fixes, re-run /review-spec until clean
```

`/create-spec` already runs `/review-spec` internally (phases 9 & 11), so a separate review is only needed for spot-checks or after manual edits.

## /create-spec

- Trigger: "add support for <chain>", "create a Lava spec for <chain>", or positional args:
  ```
  /create-spec Iota   IOTA      IOTAT
  #            name   mainnet   testnet  [+ free-text: docs/RPC URLs, inheritance hints]
  ```
- Asks you for: chain name, mainnet index, testnet index (required); docs URL, RPC URLs, inheritance hint (optional — it researches these if omitted).
- If `<chain>.json` exists it asks: use as base / adapt / scratch.

**Rerun / resume:**
- Full rerun: just `/create-spec` again (overwrite only on your confirmation).
- Partial: it supports CI entry points "Start at Phase N" (N ∈ 8,9,10,11) — boot/probe, review, fix, final review — reusing the committed `<chain>.json`. Use when only the late stages failed.
- Single tier override: tell it a `model:` to run everything cheap, or bump `spec-builder` to opus for hard chains.

## /review-spec

```
/review-spec <path-to-spec.json> [path-to-api-docs] [path-to-credentials]
```

- Only the spec path is required. Pass API docs (OpenAPI YAML/JSON) to enable the coverage diff; pass credentials for live testing.
- Read-only — produces findings, does not edit the spec. Re-run after applying fixes.

## /eval-spec

- Trigger: "eval/tune create-spec", "run the autoresearch loop on create-spec".
- Needs a local clone of `Magma-Devs/lava-specs` (ground truth). Set `LAVA_SPECS_REPO=<path>` if not auto-found.
- Backs up `create-spec/` before editing; loops 8–30 iterations (or 2h), converges at 3 consecutive batch averages > 85.
- Fast tier = deterministic (`scripts/compare_spec.sh`); deep tier adds LLM judgment + live RPC probes.
> ⚠️ Token-heavy: each iteration generates ~7 specs and runs evaluator/tuner agents — expect large token spend over a full run. Use sparingly.

**Rerun:** just re-invoke. To revert a bad tuning run, restore from the `create-spec.backup-<timestamp>` dir it created.

## /testing-chain-specs-locally

- Trigger: "test/run/boot spec PR <n> locally", "verify the `<chain>` spec with the smart-router".
- Boots the committed `<chain>.json` through a local smart-router binary (`${SMARTROUTER_BIN:-../smart-router/build/smartrouter}`) against real mainnet + testnet endpoints and reports PASS/FAIL per interface/leg (http/ws/grpc, archive, subscription).
- Iron rule: all traffic goes **through** the router — never curl/websocat a node directly. The router's boot verifications and relay logs are the evidence.
- Read-only w.r.t. the spec: it runs the spec, it does not edit it. Can post a manual-run results comment on the spec PR.

## Running in CI (GitHub Actions)

Two workflows automate the same pipeline headless:

- **Create Spec** (`create_spec.yml`) — Actions tab → "Create Spec" → Run workflow. Inputs: `chain_name`, `chain_mainnet_index`, `chain_testnet_index`, `additional_data` (docs/node URLs, hints). Runs phases 1–7 and opens a PR.
- **Spec Pipeline** (`spec_pipeline.yml`) — fires automatically when that PR opens (boot/probe → review → fix → final, phases 8–11).

Both workflows run the removed-field guard (`check_unused_fields.sh`, strict) as a hard gate: **Create Spec** checks the freshly written spec before it commits/opens the PR, and **Spec Pipeline** checks the PR's spec after the Phase-10 fix pass before it commits — either fails the run if any of the 15 removed fields is present.

**Create Spec** example:
<kbd>
  <img width="1300" height="917" alt="image" src="https://github.com/user-attachments/assets/c98cc2ae-5ed5-47b9-8984-e88979b76ddd" />
</kbd>

**Rerun phases via PR comment** (on the spec PR):
```
/rerun-probe    # Phase 8  (optional: mainnet=URL testnet=URL, or mainnet=use=PAID_RPC_1)
/rerun-review   # Phase 9
/rerun-fix      # Phase 10
/rerun-final    # Phase 11
/rerun-from 8   # re-run from phase N onward (8|9|10|11)
```

> ⚠️ A URL passed inline to `/rerun-probe` (e.g. `mainnet=https://node/?key=...`) lands in the PUBLIC PR comment and run log. If it embeds a token/API key, treat it as leaked and rotate it after the run — or reference a stored secret instead (`mainnet=use=PAID_RPC_1`).

### Required GitHub secrets

| Secret | Required | Used for |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | yes | Claude auth — generate with `claude setup-token` (expires, rotate periodically). Swap to `ANTHROPIC_API_KEY` if subscription quotas throttle. |
| `BOT_PAT` | yes | Classic PAT with `repo` + `workflow` + `read:packages`. Opens the PR (so `pull_request` events fire) and pulls the smart-router image from GHCR. |
| `PAID_RPC_1` / `PAID_RPC_2` / `PAID_RPC_3` | no | Paid RPC node URLs for boot/probe (Phase 8). |
| `PAID_WS_1` | no | Paid WebSocket URL for subscription probing. |

One-time repo setup: Settings → Actions → General → Workflow permissions → enable **"Allow GitHub Actions to create and approve pull requests"**, and ensure the `create-spec` skill is present on `main`.
