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
  scan.sh                 stdin text in -> same text out, secrets redacted
adapters/
  claude-code/           — Claude Code PostToolUse hook glue
    hook.sh
    settings-snippet.json
  (opencode/, codex/, hermes/ — planned, not yet implemented)
tests/
  test_core.sh
  test_claude_code_adapter.sh
  fixtures/
```

`core/scan.sh` is the only place that knows about gitleaks. Every
adapter's job is just: pull the right text field out of that tool's
hook/plugin payload, pipe it through `core/scan.sh`, and put the result
back in whatever shape that tool expects. Adding support for a new
agent tool (OpenCode, Codex, Hermes, ...) means writing a new adapter,
not touching the core.

## Claude Code adapter (v1, current)

1. Copy or clone this repo somewhere stable.
2. Add the hook to your Claude Code `settings.json` (global
   `~/.claude/settings.json` or project `.claude/settings.json`) — see
   `adapters/claude-code/settings-snippet.json` for the exact shape.
   Point `command` at the absolute path to `adapters/claude-code/hook.sh`.
3. Requires `gitleaks`, `jq`, and `python3` on PATH.

### Verifying against a live payload

The adapter's field-extraction logic (`tool_response.stdout` /
`.output` / `.content` / ...) was written against the documented
PostToolUse hook shape, **not yet confirmed against a live Claude Code
session**. Before relying on this:

```
SECRET_GUARD_DEBUG=1 SECRET_GUARD_DEBUG_LOG=/tmp/secret-guard-debug.jsonl \
  <run Claude Code, trigger a Bash/Read/Grep/WebFetch call>
```

then inspect `/tmp/secret-guard-debug.jsonl` and confirm
`adapters/claude-code/hook.sh`'s `jq` extraction actually finds the
tool's output text. Adjust the field list if the real payload differs.

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
- [ ] OpenCode adapter
- [ ] Codex adapter
- [ ] Hermes adapter
- [ ] Optional custom gitleaks ruleset (org-specific patterns)
- [ ] Package as a grāmatr plugin component so it ships by default for
      grāmatr users, independent of which underlying agent tool they're on

## License

MIT — see `LICENSE`.
