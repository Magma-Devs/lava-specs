#!/usr/bin/env bash
# run_stats.sh — at end of a create-spec run, report wall-clock elapsed time and
# REAL token consumption parsed from this session's transcript + all subagent
# transcripts, scoped to entries at/after the run-start epoch.
#
# Token counts are read from the harness-written .jsonl transcripts (each
# assistant message carries a .message.usage block), NOT estimated. Cache reads
# dominate the total billed figure on multi-agent runs; "fresh" = input+output.
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <start_epoch_seconds> [project_transcript_dir]" >&2
  echo "  start_epoch_seconds: value of \`date +%s\` captured at Phase 1" >&2
  echo "  project_transcript_dir: override (default: derived from cwd under ~/.claude/projects)" >&2
  exit 2
fi

START="$1"
if ! [[ "$START" =~ ^[0-9]+$ ]]; then
  echo "start_epoch_seconds must be an integer (got: $START)" >&2
  exit 2
fi

# Resolve the project transcript directory. Claude Code stores transcripts at
# ~/.claude/projects/<cwd-with-slashes-as-dashes>/. Allow an override for tests.
if [[ $# -eq 2 ]]; then
  PROJDIR="$2"
else
  ENCODED=$(pwd | sed 's#/#-#g')
  PROJDIR="$HOME/.claude/projects/$ENCODED"
fi
[[ -d "$PROJDIR" ]] || { echo "transcript dir not found: $PROJDIR" >&2; exit 1; }

# The live session transcript is the most-recently-modified top-level .jsonl
# (it is being appended to throughout the run, so it is newest at run end).
MAIN=$(ls -t "$PROJDIR"/*.jsonl 2>/dev/null | head -1 || true)
[[ -n "$MAIN" && -r "$MAIN" ]] || { echo "no session transcript found in $PROJDIR" >&2; exit 1; }
SID=$(basename "$MAIN" .jsonl)

# Subagent transcripts for this session (may be absent if no agents ran).
shopt -s nullglob
SUBS=( "$PROJDIR/$SID/subagents/"agent-*.jsonl )
shopt -u nullglob

# Sum usage across the given files, counting only entries at/after $START.
# Prints (tab-separated): api_calls input output cache_read cache_write min_ts max_ts
# where min_ts/max_ts are the epoch seconds of the first/last in-window entry
# (-1 if none). Elapsed is derived from these transcript timestamps — one
# consistent server clock — so it does not depend on the wall-clock at run end.
sum_usage() {
  cat "$@" 2>/dev/null | jq -rs --argjson start "$START" '
    def ep: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
    map(select(.timestamp and (.message.usage != null) and ((.timestamp|ep) >= $start)))
    | (map(.timestamp|ep)) as $ts
    | [ length,
        (map(.message.usage.input_tokens // 0)|add // 0),
        (map(.message.usage.output_tokens // 0)|add // 0),
        (map(.message.usage.cache_read_input_tokens // 0)|add // 0),
        (map(.message.usage.cache_creation_input_tokens // 0)|add // 0),
        ($ts|min // -1),
        ($ts|max // -1) ]
    | @tsv'
}

read -r m_calls m_in m_out m_cr m_cw m_min m_max < <(sum_usage "$MAIN")
if [[ ${#SUBS[@]} -gt 0 ]]; then
  read -r s_calls s_in s_out s_cr s_cw s_min s_max < <(sum_usage "${SUBS[@]}")
else
  s_calls=0 s_in=0 s_out=0 s_cr=0 s_cw=0 s_min=-1 s_max=-1
fi

calls=$(( m_calls + s_calls ))
in=$(( m_in + s_in ));      out=$(( m_out + s_out ))
cr=$(( m_cr + s_cr ));      cw=$(( m_cw + s_cw ))
fresh=$(( in + out ));      total=$(( in + out + cr + cw ))

# Global first/last activity timestamp across main + subagents (ignore -1 sentinels).
MIN=-1; MAX=-1
for v in "$m_min" "$s_min"; do
  if [[ "$v" != -1 ]] && { [[ "$MIN" == -1 ]] || (( v < MIN )); }; then MIN="$v"; fi
done
for v in "$m_max" "$s_max"; do
  if [[ "$v" != -1 ]] && { [[ "$MAX" == -1 ]] || (( v > MAX )); }; then MAX="$v"; fi
done
if [[ "$MIN" == -1 || "$MAX" == -1 ]]; then ELAPSED=0; else ELAPSED=$(( MAX - MIN )); fi
(( ELAPSED < 0 )) && ELAPSED=0
H=$(( ELAPSED / 3600 )); M=$(( (ELAPSED % 3600) / 60 )); S=$(( ELAPSED % 60 ))

echo "=== create-spec run stats ==="
printf 'Elapsed:         %02dh %02dm %02ds  (first→last logged activity)\n' "$H" "$M" "$S"
printf 'Transcripts:     1 main + %d subagent\n' "${#SUBS[@]}"
printf 'API round-trips: %d  (main=%d, subagents=%d)\n' "$calls" "$m_calls" "$s_calls"
echo
printf 'Fresh tokens:    input=%d  output=%d  (sum=%d)\n' "$in" "$out" "$fresh"
printf 'Cached tokens:   cache_read=%d  cache_write=%d\n' "$cr" "$cw"
printf 'Total billed:    %d tokens\n' "$total"
echo
printf 'Split (total billed):  main=%d  subagents=%d\n' \
  "$(( m_in + m_out + m_cr + m_cw ))" "$(( s_in + s_out + s_cr + s_cw ))"
echo

# Per-model breakdown — which tier(s) actually ran (.message.model on each line),
# with call count and total billed tokens. Reveals the hybrid mix in practice.
echo "Models used:"
ALLFILES=( "$MAIN" )
[[ ${#SUBS[@]} -gt 0 ]] && ALLFILES+=( "${SUBS[@]}" )
model_rows=$(cat "${ALLFILES[@]}" 2>/dev/null | jq -rs --argjson start "$START" '
  def ep: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
  def billed: (.input_tokens // 0) + (.output_tokens // 0)
            + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0);
  map(select(.timestamp and (.message.usage != null) and ((.timestamp|ep) >= $start)))
  | group_by(.message.model // "unknown")
  | map({m: (.[0].message.model // "unknown"),
         calls: length,
         billed: (map(.message.usage | billed) | add // 0)})
  | sort_by(-.billed)[]
  | "\(.m)\t\(.calls)\t\(.billed)"')
if [[ -z "$model_rows" ]]; then
  echo "  (no usage entries in window)"
else
  while IFS=$'\t' read -r mdl mc mb; do
    [[ -z "$mdl" ]] && continue
    printf '  %-22s %4d calls   %d billed\n' "$mdl" "$mc" "$mb"
  done <<< "$model_rows"
fi
