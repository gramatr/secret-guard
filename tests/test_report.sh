#!/usr/bin/env bash
# Smoke test for core/report.sh in its fail-open (no Kestra creds) mode.
# The actual Zammad-posting path needs a live Kestra endpoint and isn't
# covered here — see soc2-coordination's kestra/flows/secret-leak-to-zammad.yaml
# for that side.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/../core/report.sh"

pass=0
fail=0

LOG="$(mktemp)"
rm -f "$LOG"

findings='[{"RuleID": "aws-access-token", "StartLine": 1, "Fingerprint": "f:aws-access-token:1"}]'

unset KESTRA_PUBLIC_URL KESTRA_WEBHOOK_KEY_SECRET_LEAK
out="$(echo "$findings" | SECRET_GUARD_SOURCE="ci" SECRET_GUARD_LOCAL_LOG="$LOG" "$REPORT" 2>&1)"

if [ -f "$LOG" ] && grep -q "aws-access-token" "$LOG" && ! grep -qE "AKIA" "$LOG"; then
  echo "PASS: fail-open path logs findings locally with no secret value"
  pass=$((pass + 1))
else
  echo "FAIL: fail-open local log missing or malformed"
  echo "--- log ---"; cat "$LOG" 2>/dev/null
  fail=$((fail + 1))
fi
rm -f "$LOG"

out="$(echo "[]" | SECRET_GUARD_SOURCE="ci" SECRET_GUARD_LOCAL_LOG="$LOG" "$REPORT" 2>&1)"
if [ ! -f "$LOG" ]; then
  echo "PASS: empty findings produce no report"
  pass=$((pass + 1))
else
  echo "FAIL: empty findings should not write a log entry"
  fail=$((fail + 1))
fi
rm -f "$LOG"

echo
echo "report: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
