# critique

A [Claude Code skill](https://docs.anthropic.com/en/docs/claude-code/skills) that performs adversarial review of plans, design docs, code, or projects — like a lawyer reviewing a contract on your behalf.

## What it does

When invoked with `/critique`, it spawns one or two fresh-eyes critic agents to review the target material (code, design doc, recent commits, plan-mode plan), archives the run, and then synthesizes the findings into a triage your conversation can act on.

Each critic reports findings ranked by severity:

1. **Showstoppers** — fundamentally wrong approaches, security issues, architectural mistakes
2. **Gaps** — missing error handling, unhandled edge cases, deferred decisions
3. **Inconsistencies** — contradictions between sections, shifting terminology
4. **Underspecified areas** — ambiguities where an implementer might guess wrong
5. **Suggestions** — simpler approaches, unnecessary complexity
6. **What looks good** — brief note on what's solid (calibrates trust)

Modes:

- **Opus only** (default) — spawn one Claude Opus critic via the Agent tool.
- **Codex only** — spawn one [Codex](https://github.com/openai/codex) critic via a bundled bash helper (`run_codex.sh`). Requires the `codex` CLI on PATH.
- **Both** — fire both critics in parallel; the orchestrator then writes a cross-critic triage (where they agree, where they diverge), independently verifies specific file:line claims, and categorizes each finding as Worth-fixing / Matter-of-taste / Wrong.

Every run is archived to `runs/<timestamp>-<slug>.md` for later reference.

The skill auto-detects the target from arguments you pass, falling back to conversation context (e.g. "the latest plan" → the plan-mode plan you just generated) and then to disk-scan heuristics.

## Install

```bash
git clone https://github.com/dlowd/claude-skill-critique ~/.claude/skills/critique
```

## Prerequisites

- **Claude Code.** This is a Claude Code skill — it runs inside Claude Code, not standalone.
- **`codex` CLI on PATH and authenticated** (only for `codex` and `both` modes). Install per the [Codex repo](https://github.com/openai/codex), then run `codex login` once. If `codex` isn't installed, those modes return a clear "[codex exec failed: codex not on PATH]" message; if it's installed but you haven't logged in, you'll get an auth error in the diagnostic dump. The default Opus-only mode works regardless.
- **`timeout` (GNU coreutils).** Linux ships this by default. On macOS, `brew install coreutils` gives you `gtimeout`, which the skill auto-detects. Without either, codex runs unbounded — annoying if it hangs but not blocking.
- **Sandbox-disable permission.** Codex needs to write to its own state directory and start a local app-server, which the default Claude Code agent sandbox blocks. The skill detects this and retries with `dangerouslyDisableSandbox: true`; you'll be prompted to approve once on first use. Codex's own `--sandbox read-only` flag keeps it from modifying your project.

## Usage

In Claude Code:

```
/critique                          # Opus only, auto-detect target
/critique path/to/file.py          # Opus, specific file
/critique "use of ffmpeg"          # Opus, topic across the codebase
/critique "commits from today"     # Opus, recent changes
/critique codex <target>           # Codex only (requires `codex` CLI)
/critique both <target>            # both critics in parallel + cross-critic triage
```

## Design principles

- **Be specific** — reference exact files, lines, and decisions, not vague "could be better"
- **Be honest about severity** — don't inflate minor issues to fill a list
- **Identify problems, don't rewrite** — the user wants to know what's wrong
- **Speculative findings must name a mechanism** — "this might be slow" isn't enough; name what breaks and how
- **Intentional decisions can still be wrong** — deliberateness doesn't get a pass

## Customization

The skill is three files in `~/.claude/skills/critique/`:

- `SKILL.md` — orchestration (mode parsing, target resolution, parallel critic spawning, archive, triage). Edit to change how the skill runs.
- `critique_prompt.md` — the reviewer-persona prompt that both critics read. Edit to change severity categories, ground rules, output format, or the lawyer-reviewing-a-contract framing.
- `run_codex.sh` — bash helper for the Codex critic (handles tempfile fallback, timeout, sandbox-aware logging). Only edit if you need to change how Codex is invoked.

Fork the repo and adjust whichever matches your intent.

## License

MIT
