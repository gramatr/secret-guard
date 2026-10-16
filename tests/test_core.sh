#!/usr/bin/env bash
# Smoke test for core/scan.sh against the fixtures in tests/fixtures/.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/../core/scan.sh"

pass=0
fail=0

assert_redacted() {
  local fixture="$1"
  local out
  out="$("$SCAN" < "$SCRIPT_DIR/fixtures/$fixture")"
  if echo "$out" | grep -q "REDACTED:SECRET" && ! echo "$out" | grep -qE "AKIA|ghp_"; then
    echo "PASS: $fixture redacted"
    pass=$((pass + 1))
  else
    echo "FAIL: $fixture not redacted as expected"
    echo "--- output ---"
    echo "$out"
    fail=$((fail + 1))
  fi
}

assert_unchanged() {
  local fixture="$1"
  local in out
  in="$(cat "$SCRIPT_DIR/fixtures/$fixture")"
  out="$("$SCAN" < "$SCRIPT_DIR/fixtures/$fixture")"
  if [ "$in" = "$out" ]; then
    echo "PASS: $fixture left unchanged"
    pass=$((pass + 1))
  else
    echo "FAIL: $fixture was modified but should not have been"
    fail=$((fail + 1))
  fi
}

assert_redacted "aws_key.txt"
assert_redacted "private_key.txt"
assert_unchanged "clean.txt"

echo
echo "core: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
