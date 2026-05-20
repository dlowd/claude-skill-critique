# Local layout

`README.md` is the public/GitHub-facing description (install instructions, usage, design principles). This file documents the local on-disk layout — what each file does, what's tracked vs. untracked, and where the runtime state lives.

## Files

| File | Shipped? | Role |
|---|---|---|
| `README.md` | yes | Public description for the GitHub repo: what the skill does, install, usage, prerequisites. |
| `LICENSE` | yes | MIT. |
| `SKILL.md` | yes | The active skill definition. Runs in main conversation context (not forked), so it has access to your conversation history when resolving targets and writing the triage. Parses mode, resolves TARGET, spawns critics in parallel, archives the run, writes the triage. |
| `critique_prompt.md` | yes | The reviewer-persona prompt that both critics read. Defines the "skeptical lawyer" framing, the finding categories (Showstoppers → Suggestions), ground rules, and output format. Same prompt for Opus and Codex. |
| `run_codex.sh` | yes | Bash helper that invokes `codex exec` with the prompt. Handles tempfile fallback for sandbox-blocked `$TMPDIR`, optional timeout (10 min, requires GNU coreutils `timeout`/`gtimeout`), stdout+stderr capture, and writes a ground-truth log. The skill invokes it as a one-liner so the global "no long inline scripts" hook doesn't trip. |
| `LAYOUT.md` | yes | This file. |
| `.gitignore` | yes | Ignores the two local-only artifacts below. |
| `SKILL.md.fork-version` | no, gitignored | **Local rollback backup**, only appears on machines where the 2026-05-14 redesign was applied in-place. The pre-redesign fork-context version. If the main-context SKILL.md ever needs to be rolled back, copy this file's contents over `SKILL.md`. Fresh installs from GitHub won't have it. |
| `runs/` | no, gitignored | **Local archive directory.** Each invocation writes a timestamped `.md` file with both critique sections. Created on first run. No retention policy — clean periodically if it grows. |

## Runtime state outside this directory

- `/tmp/claude/critique-last-codex-output.log` — ground-truth log of what `run_codex.sh` actually printed on the most recent run. Clobbered each invocation. Useful when parent-Claude's reply looks suspiciously summarized — `cat` this to see the real output.

## Architectural notes

**Main-context orchestration (2026-05-14 redesign).** The skill used to run as `context: fork` — the entire orchestration happened in a forked agent that emitted critiques and tried to instruct parent-Claude via embedded meta-instructions. Parent-Claude consistently misread the meta-instructions (treated them as content to display, or as work to do solo). Redesigned to run in main context: parent-Claude itself is the orchestrator, spawning forked subagents for the critic work (Agent tool for Opus, Bash for Codex) but keeping the synthesis/triage role for itself. This way the verbatim-vs-triage boundary is just "your tool results vs your reply" rather than a fragile in-band instruction. See `SKILL.md.fork-version` for the prior shape if you ever need to compare.

**Sandbox handling for codex.** Codex needs to write to its own state directory and start a local app-server, both of which the default agent sandbox blocks with `Operation not permitted`. `SKILL.md` instructs parent-Claude to detect that pattern in the script's output and immediately retry the bash call with `dangerouslyDisableSandbox: true`. Codex's own `--sandbox read-only` flag stays on, so disabling the outer sandbox doesn't let codex modify the project — it just lets codex do its own internal bookkeeping. First-time use prompts for permission; subsequent runs are automatic.

**Target resolution moved upstream.** `critique_prompt.md` still contains target-resolution fallback heuristics (disk-scan `~/.claude/plans/`, compare against `git log`, etc.), but these are now defense-in-depth. Normal flow: parent-Claude in main context resolves vague targets like "the plan" / "recent changes" using conversation history *before* spawning critics. Critics receive concrete file paths and don't need to disk-scan. The fallback in `critique_prompt.md` is the safety net for when main-context resolution fails.
