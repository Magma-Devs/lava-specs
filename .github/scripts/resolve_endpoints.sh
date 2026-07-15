#!/usr/bin/env bash
# Resolve the endpoint set Phase 8 boots against.
# Precedence: comment override > pr_body ENDPOINTS block > self-research.
# Inputs (env): COMMENT_MAINNET, COMMENT_TESTNET (may be empty), PR_BODY_FILE.
# Emits ENDPOINT_SOURCE / MAINNET_URLS / TESTNET_URLS. ws is NOT a separate
# input: each URL is probed over http AND ws by the skill (see phase-entrypoints.md).
set -uo pipefail

mainnet="${COMMENT_MAINNET:-}"
testnet="${COMMENT_TESTNET:-}"
source_label="comment"

if [ -z "$mainnet" ] && [ -z "$testnet" ]; then
  source_label="pr_body"
  if [ -n "${PR_BODY_FILE:-}" ] && [ -f "$PR_BODY_FILE" ]; then
    block="$(awk '/<!-- ENDPOINTS/{f=1;next} /-->/{f=0} f' "$PR_BODY_FILE")"
    mainnet="$(printf '%s\n' "$block" | sed -nE 's/^mainnet:[[:space:]]*//p' | head -1 | tr -d ' \r')"
    testnet="$(printf '%s\n' "$block" | sed -nE 's/^testnet:[[:space:]]*//p' | head -1 | tr -d ' \r')"
  fi
fi

if [ -z "$mainnet" ] && [ -z "$testnet" ]; then
  source_label="self_research"
fi

printf 'ENDPOINT_SOURCE=%s\n' "$source_label"
printf 'MAINNET_URLS=%s\n' "$mainnet"
printf 'TESTNET_URLS=%s\n' "$testnet"
