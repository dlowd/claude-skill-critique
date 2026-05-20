---
name: critique
description: Adversarial review of a plan, design doc, code, or project — like a lawyer reviewing a contract on the user's behalf. Use when the user wants a skeptical second opinion before committing to an approach.
disable-model-invocation: true
allowed-tools: Agent, Read, Grep, Glob, Bash, WebFetch, WebSearch
---

You are orchestrating an adversarial critique from main conversation context. You handle target resolution, parallel spawning, archival, and the final triage. The actual critique work happens in nested forked subagents (Opus via the Agent tool, Codex via a bash helper) so the critics remain independent of your conversation history.

The reviewer prompt for both critics lives at `~/.claude/skills/critique/critique_prompt.md`.

**Arguments:** `$ARGUMENTS`

## 1. Parse mode

Inspect the first whitespace-delimited token of `$ARGUMENTS`:

- starts with `codex ` — Codex only; the rest of the string is the review target.
- starts with `both ` — Claude Opus *and* Codex; the rest of the string is the review target.
- anything else — Claude Opus only (default); the whole `$ARGUMENTS` is the review target.

Call the resulting target string **TARGET**.

## 2. Resolve TARGET to a concrete reference

You are in main conversation context — use it. The forked subagents will not have this advantage.

- If TARGET names a specific file path, commit range, or other unambiguous reference → use as-is.
- If TARGET is vague ("the plan", "the latest plan", "the design doc", "the recent commit", "recent changes") → resolve from conversation history first. If a plan was generated via plan mode in this session, you'll know its path (look for paths under `~/.claude/plans/` mentioned in the conversation). If recent commits or files came up, you know which ones.
- If TARGET is empty or conversation history doesn't disambiguate → fall back: sort `~/.claude/plans/*.md` by mtime for the most recent plan-mode plan; compare against `git log --oneline -5` and `.design/*.md` mtimes (the crosslink plugin's `/design` output dir, if present); pick the newest.

Resolve to one concrete TARGET string before spawning. Critics work better with an unambiguous target than with "go find it."

## 3. Prepare the subagent prompt

Read `~/.claude/skills/critique/critique_prompt.md` once. The full text of that file, followed by an appended `\n\nYour review target: <TARGET>\n`, is the prompt you'll pass to the Opus critic.

## 4. Spawn critics

For `both` mode: fire the Opus Agent call and the Codex Bash call **in parallel** by putting both tool calls in the same assistant message. For single-critic modes, fire just one.

### Opus critic

Use the Agent tool:

- `subagent_type`: `"general-purpose"`
- `description`: short, e.g. `"Critique <short target name>"`
- `model`: `"opus"`
- `prompt`: the prepared prompt (critique_prompt.md text + appended target line)

The subagent will read whatever files TARGET requires, form findings, and return a single message — the critique markdown. Take its final message verbatim as the Opus critique.

### Codex critic

Run the bundled helper script, passing TARGET via stdin using a single-quoted heredoc so that shell metacharacters in the target text (backticks, `$(...)`, etc.) can't be interpreted by the shell:

```bash
bash ~/.claude/skills/critique/run_codex.sh <<'CRITIQUE_TARGET_EOF'
<TARGET literal here — any characters allowed, multiline OK, no shell interpolation>
CRITIQUE_TARGET_EOF
```

The single-quoted delimiter (`'CRITIQUE_TARGET_EOF'`) is what blocks shell interpolation; do not omit the quotes. The delimiter name itself is arbitrary; if your TARGET happens to contain the literal string `CRITIQUE_TARGET_EOF` on its own line, pick a longer one.

The script handles prompt assembly, tempfiles, timeout, and stderr/stdout capture. Its stdout is either the Codex critique (success path, exit 0) or a diagnostic dump (`[codex exec failed...]` line + `---codex stderr---` block + `---codex stdout (tail)---` block + `---codex env---` block; exit non-zero).

**Sandbox handling.** Codex needs to write to its own state directory and spin up a local app-server, both of which the default agent sandbox blocks with `Operation not permitted (os error 1)`. If the script's first run returns non-zero exit AND its output contains `Operation not permitted`, `failed to initialize in-process app-server`, or similar sandbox-permission errors, immediately retry the same Bash call with `dangerouslyDisableSandbox: true`. This matches the standing instruction in `~/.claude/CLAUDE.md`. Don't ask first — codex is read-only by virtue of its own `--sandbox read-only` flag, so disabling the *outer* sandbox just lets codex do its internal setup. Briefly mention in your reply that the sandbox-disabled retry was needed (the user wants to know).

**Verbatim relay.** Take the script's stdout VERBATIM as the Codex critique. This applies equally to success AND failure output. Do NOT summarize, paraphrase, or interpret diagnostic blocks. If the script's output looks like log noise rather than a critique, that IS the critique for this run — relay it whole. The user explicitly wants the raw failure diagnostics, not a TL;DR. Editorializing failure output ("looks like a sandbox issue") loses the information needed to actually diagnose what's going wrong; if you have a hypothesis, save it for the Triage section, but include the raw script output above it.

The script also writes its full output to `/tmp/claude/critique-last-codex-output.log` (clobbered each run) as a ground-truth backup — if the script output ever feels suspiciously summarized, that file is the source of truth.

## 5. Archive

After both critics return, save to `~/.claude/skills/critique/runs/<timestamp>-<slug>.md`:

- `mkdir -p ~/.claude/skills/critique/runs` first.
- Timestamp: ISO 8601 with colons replaced by hyphens (filesystem-safe). Example: `2026-05-14T17-30-00`.
- Slug: TARGET lowercased, non-alphanumerics replaced with hyphens, collapsed runs of hyphens, max 40 chars.
- Contents: a header noting target / mode / timestamp; then the Opus critique section (if run); then the Codex critique section (if run).

If a critic failed (Codex script returned a fallback line, or the Agent call returned an error), still archive what you got — the failure is a useful record.

## 6. Reply to the user

Compose your final reply in this order:

1. **Archive notice** — one line: `> Critique archive: <full path>`
2. **Critique sections verbatim**:
   - Opus only: just the Opus section under `## Critique (Claude Opus)`.
   - Codex only: just the Codex section under `## Critique (Codex)`.
   - Both: Opus section first, then Codex section.
3. **Your `## Triage` section.** This is the main-context payoff. You have:
   - Both critique results (full text)
   - Your conversation context (what was discussed, what the user values, what was just generated)
   - Read/Grep/Bash to verify specific claims

### Triage instructions

For each distinct finding across the critiques:

1. **Cross-critic synthesis** (when both ran). Did both critics flag this? Agreement raises confidence. Did they disagree on severity or interpretation? That divergence is itself a finding worth surfacing.
2. **Independent verification.** For claims that name a file:line, function name, or specific behavior, use Read / Grep / Bash to check the code yourself. The critics gave their best read; you can confirm or refute directly.

Categorize each finding as one of:

- **Worth fixing.** Real issue with concrete benefit. If both critics flagged it, note that. Say whether it's small enough to do now or worth deferring.
- **Matter of taste / judgment call.** Could go either way; not wrong, but not clearly right either. State the tradeoff in one sentence.
- **Wrong.** Name what the critic claimed, what's actually true, and how you verified it (file:line, grep result, command output). If you can't verify and you're just disagreeing on intuition, mark it "I disagree but haven't verified" — the user wants to know when you're hedging rather than taking a hedged claim at face value.

Be explicit when uncertain. A confident-wrong triage is worse than a hedged-uncertain one. If a finding doesn't fit cleanly into the three buckets, say so rather than forcing it.

Do NOT propose code edits in the triage. Triage is decision support; edits come after the user picks which findings to act on.

## Notes

- The Agent tool and Bash tool can both run in a single assistant message — that's how you get parallelism for `both` mode. Critic runs are minutes-long; don't serialize them.
- Subagents return only their final message; their intermediate tool calls and reasoning stay in their own context, not yours.
- If the user runs `/critique` with no arguments and you can't resolve a TARGET from conversation history or disk-scan fallback, explain the ambiguity and ask rather than picking blindly.
