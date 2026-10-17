#!/usr/bin/env bash
# adapters/claude-code/hook.sh — PostToolUse hook glue for Claude Code.
#
# BASH-ONLY, STRUCTURED OUTPUT — found the hard way, while building
# gramatr/claude-plugin-guards: Claude Code's updatedToolOutput schema
# is PER TOOL, and only Bash's shape is confirmed from the docs — a
# structured object, not a bare string:
#   {"stdout": "...", "stderr": "...", "interrupted": false, "isImage": false}
# "A value that doesn't match the tool's output schema is ignored and
# the original output is used." This script used to return a bare
# string and matched Read|Grep|WebFetch too — that means it would have
# silently no-op'd on every tool if ever wired into a real settings.json,
# since Bash needed the object shape and the others' shapes were never
# confirmed. Fixed: Bash only, correct shape, exits 0 (safe pass-through)
# for anything else. See README "Known limitations."
#
# Also found at the same time: if multiple PostToolUse hooks are matched
# on the same tool call, Claude Code's own docs say they run in parallel
# with an undefined resolution order for updatedToolOutput. If you're
# using secret-guard alongside injection-guard/pii-guard, prefer
# gramatr/claude-plugin-guards' combined-hook.sh (runs all three in
# sequence, one deterministic result) over wiring this hook plus theirs
# independently on the same matcher.
#
# Fail-open: if core/scan.sh or gitleaks isn't reachable, passes tool
# output through unchanged and logs a warning.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/../../core/scan.sh"

RAW="$(cat)"

TOOL_NAME="$(printf '%s' "$RAW" | jq -r '.tool_name // ""' 2>/dev/null)"
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

STDOUT="$(printf '%s' "$RAW" | jq -r '.tool_response.stdout // ""' 2>/dev/null)"
STDERR="$(printf '%s' "$RAW" | jq -r '.tool_response.stderr // ""' 2>/dev/null)"
INTERRUPTED="$(printf '%s' "$RAW" | jq -r '.tool_response.interrupted // false' 2>/dev/null)"
IS_IMAGE="$(printf '%s' "$RAW" | jq -r '.tool_response.isImage // false' 2>/dev/null)"

if [ -z "$STDOUT" ]; then
  exit 0
fi

if [ ! -x "$SCAN" ]; then
  echo "secret-guard hook: core/scan.sh not found/executable, passing through (fail-open)" >&2
  exit 0
fi

REDACTED="$(printf '%s' "$STDOUT" | "$SCAN")"

if [ "$REDACTED" = "$STDOUT" ]; then
  # No findings — leave the original tool output untouched.
  exit 0
fi

jq -n \
  --arg stdout "$REDACTED" \
  --arg stderr "$STDERR" \
  --argjson interrupted "$INTERRUPTED" \
  --argjson isImage "$IS_IMAGE" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: {stdout: $stdout, stderr: $stderr, interrupted: $interrupted, isImage: $isImage}}}'
