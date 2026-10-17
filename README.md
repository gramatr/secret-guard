# secret-guard

Cross-agent secret-leak guard. Scans tool output for secrets (API keys,
tokens, private keys, ...) and redacts them before they land in an
agent's context or on-screen transcript — not after the fact.

Born out of a recurring problem with Claude Code sessions: Bash output
(env dumps, curl responses, log tails) regularly contains live
credentials, and those get echoed straight into the conversation with
nothing in between. [gitleaks](https://github.com/gitleaks/gitleaks) is
already the mandated secret scanner for committed code across our repos
— this project reuses the same engine for *live tool output*, which is a
different problem (gating a running agent session, not scanning a git
history).

## Architecture

```
core/                   — engine, no knowledge of any specific agent tool
  scan.sh                  stdin text in -> same text out, secrets redacted
  report.sh                reports findings as SOC2 compliance evidence (see below)
adapters/
  claude-code/           — Claude Code PostToolUse hook glue
    hook.sh
    settings-snippet.json
  (opencode/, codex/, hermes/ — planned, not yet implemented)
tests/
  test_core.sh
  test_claude_code_adapter.sh
  test_report.sh
  fixtures/
```

`core/scan.sh` is the only place that knows about gitleaks. Every
adapter's job is just: pull the right text field out of that tool's
hook/plugin payload, pipe it through `core/scan.sh`, and put the result
back in whatever shape that tool expects. Adding support for a new
agent tool (OpenCode, Codex, Hermes, ...) means writing a new adapter,
not touching the core.

## Compliance reporting (SOC2 evidence)

Every redaction is also a *finding that something needed to be hidden*,
which for a SOC2 program is its own auditable event. `core/scan.sh` can
emit a findings JSON (rule id, line, fingerprint — never the secret
value) via `SECRET_GUARD_FINDINGS_JSON`, and `core/report.sh` posts that
to a Kestra webhook (`secret-leak-to-zammad` in the `gramatr/soc2-coordination`
repo — see its `kestra/flows/secret-leak-to-zammad.yaml` and
`contracts/zammad.yaml`), which files a Zammad ticket and writes an
immutable ClickHouse audit-events row.

Required env for the report to actually file a ticket:
`KESTRA_PUBLIC_URL`, `KESTRA_WEBHOOK_KEY_SECRET_LEAK`. Without them,
`report.sh` fails open — it appends to a local JSONL log
(`SECRET_GUARD_LOCAL_LOG`, default `/tmp/secret-guard-events.jsonl`)
instead of silently doing nothing, so a missing credential is visible
without ever blocking the redaction that already happened.

This is deliberately generic: any adapter (or the CI gitleaks gate in
soc2-coordination) can call `report.sh` the same way. v1 attribution is
shallow by design — which control caught it (ci/pr/live-session) plus
file/rule, not who-or-what introduced the secret. See soc2-coordination's
PR history for the "why" on that scoping choice.

## Optional daemon mode (for a shared multi-guard stack)

`daemon/server.py` + `docker/Dockerfile` wrap `core/scan.sh` as an HTTP
service (`POST /scan`, `GET /health`) — for deployments running
secret-guard alongside `pii-guard`/`injection-guard` as one Docker
Compose stack with a consistent interface across all three (see
[gramatr/guards-stack](https://github.com/gramatr/guards-stack)). This
is **not** the primary interface: gitleaks has no model-load cost to
amortize, so a direct `core/scan.sh` call from an adapter (see below)
remains the simplest integration when secret-guard runs alone. Use the
daemon only when something else in the deployment already needs
`pii-guard-daemon`/`injection-guard-daemon` running as services and you
want one consistent shape.

```
docker build -t secret-guard -f docker/Dockerfile .
docker run -p 127.0.0.1:8732:8732 secret-guard
curl -X POST http://localhost:8732/scan -H 'Content-Type: application/json' \
  -d '{"text": "some text that might contain a secret"}'
```

## Claude Code adapter (v1, current)

1. Copy or clone this repo somewhere stable.
2. Add the hook to your Claude Code `settings.json` (global
   `~/.claude/settings.json` or project `.claude/settings.json`) — see
   `adapters/claude-code/settings-snippet.json` for the exact shape.
   Point `command` at the absolute path to `adapters/claude-code/hook.sh`.
3. Requires `gitleaks` and `jq` on PATH.

### Bash only — found the hard way, not a design choice

Earlier versions of this adapter matched `Bash|Read|Grep|WebFetch` and
returned `updatedToolOutput` as a bare string. Both were wrong, found
while building [gramatr/claude-plugin-guards](https://github.com/gramatr/claude-plugin-guards):
Claude Code's `updatedToolOutput` schema is **per tool**, and only
Bash's shape is confirmed from the docs — a structured object
(`{"stdout", "stderr", "interrupted", "isImage"}`), not a string. A
value that doesn't match the tool's schema is silently ignored and the
original output is used — so this adapter would have been a no-op on
every tool call, the whole time, if it had ever been wired into a real
`settings.json`. Fixed: Bash only, correct shape. Read/Grep/WebFetch's
exact shapes aren't confirmed, so rather than guess and risk the same
silent no-op, those tool calls pass through unguarded for now.

If you're also running injection-guard and/or pii-guard, prefer
`claude-plugin-guards`' combined hook over wiring this adapter
independently alongside theirs on the same matcher — Claude Code runs
same-event hooks in parallel with an undefined resolution order when
more than one returns `updatedToolOutput` for the same call.

## Fail-open vs. fail-closed

`core/scan.sh` is deliberately **fail-open**: if `gitleaks` isn't on
PATH, or the scan errors for any reason, it passes the original text
through unmodified rather than blocking the tool call. Reasoning: a
broken scanner shouldn't be able to make the host agent tool unusable.
If you'd rather fail closed (block on scanner failure) for a
higher-sensitivity environment, that's a one-line change in `scan.sh` —
not the default because it trades availability for a security property
most setups won't want by default.

## Known limitations

- **Only Bash tool calls are guarded** — see "Bash only" above.
- **Covers tool output, not model-generated text.** If the agent reads
  a secret in one tool call and later *types it out itself* in a later
  response, this does not catch that — there is no documented hook in
  Claude Code (or, so far, any other agent tool) that can intercept and
  rewrite the model's own generated text before it's added to context
  and the permanent transcript. Solving that needs either prompt-level
  discipline or a response-level interception point none of these tools
  expose yet.
- PostToolUse (and equivalent hooks in other tools) fires *after* the
  tool already executed — this redacts what reaches the agent's context
  and the visible transcript, it does not prevent the underlying command
  from having run.
- Redaction here is best-effort pattern matching (gitleaks' ruleset). It
  will miss novel/custom secret formats and can occasionally
  false-positive on high-entropy strings that aren't secrets.

## Roadmap

- [ ] Confirm Claude Code PostToolUse payload shape against a live session
- [ ] Create the `kestra-webhook-key-secret-leak` BWS secret + `secret-guard@n90.co`
      Zammad customer (prerequisites for `secret-leak-to-zammad`, not yet done)
- [ ] OpenCode adapter
- [ ] Codex adapter
- [ ] Hermes adapter
- [ ] Optional custom gitleaks ruleset (org-specific patterns)
- [ ] Deeper attribution (human commit author vs. `Co-Authored-By: grāmatr`
      trailer; Write/Edit = AI drafted vs. Bash/Read = surfaced pre-existing) —
      deferred from v1, see soc2-coordination PR history
- [ ] Package as a grāmatr plugin component so it ships by default for
      grāmatr users, independent of which underlying agent tool they're on
- [x] Optional HTTP daemon mode for a shared multi-guard Docker stack
      (`daemon/server.py`, `docker/Dockerfile`) — see "Optional daemon
      mode" above and [gramatr/guards-stack](https://github.com/gramatr/guards-stack)

## License

MIT — see `LICENSE`.
