#!/usr/bin/env bash
# core/scan.sh — tool-agnostic secret scan + redaction.
#
# Reads arbitrary text on stdin, scans it with gitleaks, and writes the
# same text back to stdout with any detected secrets replaced by
# ***REDACTED:<rule-id>***. Exits 0 always (scanning failures must not
# break the caller's pipeline — see README "fail-open vs fail-closed").
#
# On stderr: one line per finding ("REDACTED rule=<id> line=<n>"), for
# adapters that want to log/count without touching stdout.
#
# If SECRET_GUARD_FINDINGS_JSON is set, writes a JSON array of findings
# there (RuleID/StartLine/Fingerprint — no Secret/Match values) for
# adapters that want to report findings via core/report.sh without
# re-scanning the text themselves.
#
# Requires: gitleaks (>=8.x), jq, python3.

set -uo pipefail

INPUT_FILE="$(mktemp)"
REPORT_FILE="$(mktemp)"
trap 'rm -f "$INPUT_FILE" "$REPORT_FILE"' EXIT

cat > "$INPUT_FILE"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "secret-guard: gitleaks not found on PATH, skipping scan (fail-open)" >&2
  cat "$INPUT_FILE"
  exit 0
fi

gitleaks detect --no-git -s "$INPUT_FILE" --report-format json --report-path "$REPORT_FILE" --exit-code 0 >/dev/null 2>&1

if [ ! -s "$REPORT_FILE" ] || [ "$(cat "$REPORT_FILE")" = "null" ]; then
  cat "$INPUT_FILE"
  exit 0
fi

python3 - "$INPUT_FILE" "$REPORT_FILE" "${SECRET_GUARD_FINDINGS_JSON:-}" <<'PYEOF'
import json
import sys

input_path, report_path, findings_out_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(input_path, "r", errors="replace") as f:
    text = f.read()

with open(report_path, "r") as f:
    findings = json.load(f) or []

# Replace longest secrets first so overlapping/substring matches don't
# clobber each other's placeholders.
secrets = sorted({f["Secret"] for f in findings if f.get("Secret")}, key=len, reverse=True)

for finding in findings:
    rule = finding.get("RuleID", "unknown")
    line = finding.get("StartLine", "?")
    print(f"REDACTED rule={rule} line={line}", file=sys.stderr)

if findings_out_path:
    safe_findings = [
        {
            "RuleID": f.get("RuleID", "unknown"),
            "StartLine": f.get("StartLine"),
            "Fingerprint": f.get("Fingerprint", ""),
        }
        for f in findings
    ]
    with open(findings_out_path, "w") as f:
        json.dump(safe_findings, f)

for secret in secrets:
    if secret:
        text = text.replace(secret, f"***REDACTED:SECRET***")

sys.stdout.write(text)
PYEOF
