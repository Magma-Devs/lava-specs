# Pruning Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to verify pruning/archive sizing against the research-derived retention window.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON
- `<retention_blocks>` — integer block count from archive-researcher's `retention_blocks`, OR the literal `unknown`

## Algorithm

Run from repo root:

```bash
.claude/skills/create-spec/scripts/check_pruning.sh <spec_path> <retention_blocks>
```

The script:
- FAILs (exit 1) any `archive.rule.block` or `pruning.latest_distance` that is >3× larger or >3× smaller than `<retention_blocks>`.
- Emits `INFO: retention unknown` and PASSes when `<retention_blocks>` is `unknown` (cannot verify — never block on missing data).

## Return to orchestrator

```
=== GATE: pruning ===
<verbatim check_pruning.sh output>

=== SUMMARY ===
RESULT: PASS | FAIL    # mirror the script's RESULT line
```

Do NOT modify the candidate spec.

END-OF-PRUNING-VALIDATOR-SENTINEL
