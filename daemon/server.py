#!/usr/bin/env python3
"""daemon/server.py

Optional HTTP wrapper around core/scan.sh, for deployments that want
secret-guard to present the same service shape (resident process,
POST /scan, GET /health) as its siblings pii-guard-daemon and
injection-guard-daemon — e.g. a shared Docker Compose stack one level
up (see gramatr/guards-stack) that runs all three guards behind one
set of harness-agnostic HTTP endpoints.

Not the primary interface. secret-guard has no model to keep resident
(gitleaks is a fast, zero-model pattern scanner), so core/scan.sh
remains the right choice for a direct CLI/adapter integration — this
exists purely for interface consistency when secret-guard is deployed
alongside pii-guard/injection-guard, not because scan.sh benefits from
being daemonized.

No text is logged, cached, or persisted anywhere by this process —
scan.sh already discards its own temp files on exit, and this wrapper
never writes the request body to disk or to its own stdout/stderr
(only scan.sh's finding summary passes through, which never contains
the matched secret value).
"""
import http.server
import json
import os
import subprocess
import sys

HOST = os.environ.get("SECRET_GUARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("SECRET_GUARD_PORT", "8732"))
SCAN_SH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core", "scan.sh"
)


class Handler(http.server.BaseHTTPRequestHandler):
    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok"})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/scan":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            text = json.loads(raw).get("text", "") if raw else ""
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return

        try:
            result = subprocess.run(
                [SCAN_SH],
                input=text,
                capture_output=True,
                text=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            # Fail open, same posture as scan.sh's own missing-deps path.
            self._json(200, {"found": False, "redacted_text": text})
            return

        redacted = result.stdout
        # scan.sh's internal command substitution ($(cat ...)) strips
        # trailing newlines unconditionally, so a clean input with a
        # trailing newline comes back one byte shorter even though
        # nothing was redacted — found while building guards-stack's
        # end-to-end test against this exact repo's clean.txt fixture,
        # which triggered a false "found": true before this
        # normalization. Compare with trailing newlines stripped on
        # both sides.
        found = redacted.rstrip("\n") != text.rstrip("\n")
        self._json(200, {"found": found, "redacted_text": redacted})

    def log_message(self, format, *args):
        # Request-shape logging only (method/path/status) — never the
        # body, so no scanned text reaches a log line.
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def main():
    if not os.access(SCAN_SH, os.X_OK):
        os.chmod(SCAN_SH, 0o755)
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(f"secret-guard-daemon: listening on {HOST}:{PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
