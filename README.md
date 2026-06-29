# Lava Specs — skill workflow

Three skills build and maintain chain specs. Each is a slash command in Claude Code.

| Command | Does | Output |
|---|---|---|
| `/create-spec` | Onboards a new chain: research → synthesize → validate → boot/probe → review. 12-phase pipeline. | `<chain>.json` at repo root |
| `/review-spec` | Audits an existing spec: params, API coverage, block parsing, parse directives. | review report (no edits) |
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
  /create-spec Iota IOTA IOTAT
  #            name mainnet testnet  [+ free-text: docs/RPC URLs, inheritance hints]
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

**Rerun:** just re-invoke. To revert a bad tuning run, restore from the `create-spec.backup-<timestamp>` dir it created.

## Running in CI (GitHub Actions)

Two workflows automate the same pipeline headless:

- **Create Spec** (`create_spec.yml`) — Actions tab → "Create Spec" → Run workflow. Inputs: `chain_name`, `chain_mainnet_index`, `chain_testnet_index`, `additional_data` (docs/node URLs, hints). Runs phases 1–7 and opens a PR.
- **Spec Pipeline** (`spec_pipeline.yml`) — fires automatically when that PR opens (boot/probe → review → fix → final, phases 8–11).

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
