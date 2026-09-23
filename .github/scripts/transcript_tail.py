#!/usr/bin/env python3
"""Quote the agent's closing message out of a claude-code execution transcript.

Used by spec_pipeline.yml's "Verify the run span completed" step. When a run
truncates, "the agent stopped early" is true of every truncation and diagnoses
none of them — while the agent's own final message usually names the reason
outright. On PR #152 it read "Standing by for Phase 8 to complete.", which is
the entire diagnosis (the orchestrator was waiting on a subagent that had
already returned, MAG-3810). Finding it cost two runs and an artifact download.
This puts it in the PR comment instead.

Writes Markdown to stdout, or nothing at all. It runs on the failure path of a
step that is already failing, so it must never raise, never exit non-zero, and
never be the reason a truncation goes unreported: every failure mode is "print
nothing and get out of the way".

Usage: transcript_tail.py <execution_file.json>
"""
import json
import sys

# The transcript is a full agent run and can be megabytes; we only ever read the
# terminal record. Cap what we quote so a runaway final message cannot blow up a
# PR comment (GitHub's limit is 65536 characters).
MAX_QUOTE = 600

# Terminal-state fields worth showing. `stop_reason: end_turn` +
# `terminal_reason: completed` is the signature of an agent that chose to stop,
# as opposed to one that was cut off — the distinction that says whether to look
# for a crash or for a missing instruction.
STATE_FIELDS = ("stop_reason", "terminal_reason", "num_turns", "subtype")


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1]) as fh:
            data = json.load(fh)
    except Exception:
        # Missing, truncated, or not-JSON transcript. Nothing to say.
        return 0

    if not isinstance(data, list) or not data:
        return 0

    last = data[-1]
    if not isinstance(last, dict):
        return 0

    out = []

    result = last.get("result")
    if isinstance(result, str) and result.strip():
        full = result.strip()
        quoted = full[:MAX_QUOTE]
        # Say so when the quote is cut, or a reader takes a truncated closing
        # message for the whole one and reasons from half a sentence.
        if len(full) > MAX_QUOTE:
            quoted += " […truncated, see the transcript artifact]"
        # Every line needs the "> " marker or Markdown ends the blockquote at
        # the first newline and the rest reads as body text.
        body = "\n".join("> " + ln for ln in quoted.splitlines())
        out.append("The agent's final message was:\n\n" + body)

    bits = [
        "`{}: {}`".format(k, last[k])
        for k in STATE_FIELDS
        if last.get(k) is not None
    ]
    if bits:
        out.append("Terminal state: " + " · ".join(bits))

    # Both foreground and background subagent accounting, when present: a run
    # that waited on a subagent which had already completed shows
    # `completed == spawned` with `failed: 0`, which is the tell for MAG-3810.
    stats = last.get("subagent_stats")
    if isinstance(stats, dict):
        # Only the fields that are actually present — printing `completed None`
        # reads as a real value and invites the wrong conclusion about a run
        # where the count simply was not recorded.
        parts = [
            "{} {}".format(k, stats[k])
            for k in ("spawned", "completed", "failed")
            if stats.get(k) is not None
        ]
        if parts:
            out.append("Subagents: `" + " · ".join(parts) + "`")

    if out:
        print("\n\n".join(out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Belt and braces: this runs on an already-failing path.
        sys.exit(0)
