# Pruning Validator (Phase 6 of create-spec)

You are a subagent dispatched by the create-spec orchestrator to verify pruning/archive sizing against the research-derived retention window.

## Inputs (substituted by orchestrator)

- `<spec_path>` — absolute path to the candidate spec JSON
- `<retention_blocks>` — integer block count from archive-researcher's `retention_blocks`, OR the literal `unknown`

## Algorithm

Run from repo root:

```bash
.claude/skills/create-spec/scripts/check_pruning.sh <spec_path> <retention_blocks>
.claude/skills/create-spec/scripts/check_archive_value.sh <spec_path>
```

`check_pruning.sh`:
- FAILs (exit 1) any `archive.rule.block` or `pruning.latest_distance` that is >3× larger or >3× smaller than `<retention_blocks>`.
- Emits `INFO: retention unknown` and PASSes when `<retention_blocks>` is `unknown` (cannot verify — never block on missing data).

`check_archive_value.sh` (no retention arg):
- FAILs (exit 1) any archive-tier pruning `expected_value` that is not a base-10 integer on the `GET_BLOCK_BY_NUM` path with no `latest_distance` (e.g. `"*"`). The router parses it with `ParseInt` and excludes the archive provider at boot — a CRITICAL spec defect. Other `function_tag` paths and distance-based entries are not flagged.

The gate RESULT is FAIL if **either** script FAILs.

## Return to orchestrator

```
=== GATE: pruning ===
<verbatim check_pruning.sh output>
<verbatim check_archive_value.sh output>

=== SUMMARY ===
RESULT: PASS | FAIL    # FAIL if either script's RESULT is FAIL
```

Do NOT modify the candidate spec.

END-OF-PRUNING-VALIDATOR-SENTINEL
