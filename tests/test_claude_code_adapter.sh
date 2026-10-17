#!/usr/bin/env bash
# Smoke test for the Claude Code adapter. Payload shape matches Claude
# Code's confirmed PostToolUse schema for Bash (updatedToolOutput is a
# structured {stdout, stderr, interrupted, isImage} object, not a bare
# string — see README "Bash only" for how this was confirmed and why
# an earlier version of this hook got it wrong).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../adapters/claude-code/hook.sh"

pass=0
fail=0

payload_with_secret='{
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_response": {
    "stdout": "AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP\n",
    "stderr": "",
    "interrupted": false,
    "isImage": false
  }
}'

payload_clean='{
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_response": {
    "stdout": "build ok\n",
    "stderr": "",
    "interrupted": false,
    "isImage": false
  }
}'

payload_non_bash='{
  "hook_event_name": "PostToolUse",
  "tool_name": "Read",
  "tool_response": {
    "content": "AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP\n"
  }
}'

out="$(echo "$payload_with_secret" | "$HOOK")"
if echo "$out" | jq -e '.hookSpecificOutput.updatedToolOutput.stdout' >/dev/null 2>&1 \
   && ! echo "$out" | grep -q "AKIA"; then
  echo "PASS: secret payload redacted, correct structured-object shape"
  pass=$((pass + 1))
else
  echo "FAIL: secret payload not redacted correctly, or wrong shape"
  echo "--- output ---"
  echo "$out"
  fail=$((fail + 1))
fi

out="$(echo "$payload_non_bash" | "$HOOK")"
if [ -z "$out" ]; then
  echo "PASS: non-Bash tool call passes through with no hook output (Bash-only scope)"
  pass=$((pass + 1))
else
  echo "FAIL: non-Bash tool call should produce no output, got:"
  echo "$out"
  fail=$((fail + 1))
fi

out="$(echo "$payload_clean" | "$HOOK")"
if [ -z "$out" ]; then
  echo "PASS: clean payload passed through with no hook output"
  pass=$((pass + 1))
else
  echo "FAIL: clean payload should produce no stdout, got:"
  echo "$out"
  fail=$((fail + 1))
fi

echo
echo "claude-code adapter: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
