#!/usr/bin/env bash
# Smoke test for the Claude Code adapter, using a synthetic PostToolUse
# payload shape. NOTE: the payload shape here is our best guess (see
# README "Verifying against a live payload") — this test proves the
# adapter's own logic is correct, not that the guessed schema matches
# what Claude Code actually sends.
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
    "exit_code": 0
  }
}'

payload_clean='{
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_response": {
    "stdout": "build ok\n",
    "stderr": "",
    "exit_code": 0
  }
}'

out="$(echo "$payload_with_secret" | "$HOOK")"
if echo "$out" | jq -e '.hookSpecificOutput.updatedToolOutput' >/dev/null 2>&1 \
   && ! echo "$out" | grep -q "AKIA"; then
  echo "PASS: secret payload redacted via updatedToolOutput"
  pass=$((pass + 1))
else
  echo "FAIL: secret payload not redacted correctly"
  echo "--- output ---"
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
