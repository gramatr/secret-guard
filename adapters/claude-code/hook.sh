#!/usr/bin/env bash
# adapters/claude-code/hook.sh — PostToolUse hook glue for Claude Code.
#
# Claude Code invokes this with the hook payload JSON on stdin and expects
# JSON on stdout (or nothing, to pass the original tool output through
# unchanged). See core/scan.sh for the actual detection/redaction logic —
# this file is only responsible for (a) pulling the right text field out
# of Claude Code's specific payload shape and (b) putting the redacted
# result back in the shape Claude Code expects.
#
# CAVEAT: the exact field holding tool output (tool_response.stdout vs
# .output vs .content, etc.) has not been confirmed against a live
# Claude Code session yet — see README "Verifying against a live payload"
# before trusting this in production. Set SECRET_GUARD_DEBUG=1 to log the
# raw payload for inspection.
#
# On a finding, also reports it as SOC2 compliance evidence via
# core/report.sh (fail-open — see that file; a missing/unreachable
# Kestra webhook never blocks the redaction above).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/../../core/scan.sh"
REPORT="$SCRIPT_DIR/../../core/report.sh"

RAW="$(cat)"

if [ "${SECRET_GUARD_DEBUG:-0}" = "1" ]; then
  echo "$RAW" >> "${SECRET_GUARD_DEBUG_LOG:-/tmp/secret-guard-debug.jsonl}"
fi

TEXT="$(printf '%s' "$RAW" | jq -r '
  .tool_response as $r
  | if $r == null then ""
    elif ($r | type) == "string" then $r
    elif $r.stdout != null then $r.stdout
    elif $r.output != null then $r.output
    elif $r.content != null then ($r.content | if type == "string" then . else tojson end)
    else ($r | tojson)
    end
' 2>/dev/null)"

if [ -z "$TEXT" ]; then
  exit 0
fi

FINDINGS_FILE="$(mktemp)"
trap 'rm -f "$FINDINGS_FILE"' EXIT

REDACTED="$(printf '%s' "$TEXT" | SECRET_GUARD_FINDINGS_JSON="$FINDINGS_FILE" "$SCAN")"

if [ "$REDACTED" = "$TEXT" ]; then
  # No findings — leave the original tool output untouched.
  exit 0
fi

TOOL_NAME="$(printf '%s' "$RAW" | jq -r '.tool_name // "unknown"' 2>/dev/null)"
SECRET_GUARD_SOURCE="claude-code-live-session" \
SECRET_GUARD_FILE="Claude Code ${TOOL_NAME} tool output" \
SECRET_GUARD_CONTEXT="tool=${TOOL_NAME}" \
  "$REPORT" < "$FINDINGS_FILE"

jq -n --arg out "$REDACTED" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $out}}'
