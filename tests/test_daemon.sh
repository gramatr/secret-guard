#!/usr/bin/env bash
# Smoke test for daemon/server.py — starts it against the real
# core/scan.sh, hits /health and /scan with the same fixtures
# test_core.sh uses, confirms the HTTP shape (found/redacted_text).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PORT=18732
PID=""

pass=0
fail=0

cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
}
trap cleanup EXIT

if ! command -v gitleaks >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: gitleaks/jq not on PATH, skipping daemon test"
  exit 0
fi

SECRET_GUARD_HOST=127.0.0.1 SECRET_GUARD_PORT=$PORT \
  python3 "$REPO_ROOT/daemon/server.py" >/tmp/secret-guard-daemon-test.log 2>&1 &
PID=$!

for i in $(seq 1 20); do
  if curl -sS -m 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

assert_scan() {
  local fixture="$1" expect_found="$2"
  local text found
  text="$(cat "$SCRIPT_DIR/fixtures/$fixture")"
  resp="$(curl -sS -X POST "http://127.0.0.1:${PORT}/scan" \
    -H 'Content-Type: application/json' \
    --data-binary @<(python3 -c "import json,sys; print(json.dumps({'text': sys.stdin.read()}))" <<< "$text"))"
  found="$(echo "$resp" | jq -r '.found')"
  if [ "$found" = "$expect_found" ]; then
    echo "PASS: $fixture -> found=$found"
    pass=$((pass + 1))
  else
    echo "FAIL: $fixture -> expected found=$expect_found, got $found ($resp)"
    fail=$((fail + 1))
  fi
}

assert_scan "aws_key.txt" "true"
assert_scan "clean.txt" "false"

echo
echo "daemon: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
