#!/bin/bash
# Run Codex critique with the prompt from critique_prompt.md + a user-supplied target.
#
# Bundled with the /critique skill so the skill invocation stays a one-liner
# (otherwise the multi-line inline bash trips the global "no long inline
# scripts" hook and gets rewritten as a temp-file write + run, adding noise to
# every critique invocation).
#
# Usage (preferred — TARGET via stdin, safe against shell metacharacters):
#   bash run_codex.sh <<'EOF_TARGET'
#   <target text — any characters allowed, no shell interpolation>
#   EOF_TARGET
#
# Usage (legacy / manual testing — TARGET as $1):
#   bash run_codex.sh "<target string>"
#
# Exit code contract (load-bearing — SKILL.md's sandbox-retry depends on this):
#   0  : codex critique succeeded; stdout is the critique
#   !=0: something went wrong; stdout is a diagnostic dump
#        - propagates codex's own exit status when codex ran but failed
#        - 1 for early failures (missing prompt file, codex not on PATH, no
#          writable tempfile, empty TARGET)
#
# Behavior:
# - Reads critique_prompt.md from this script's own directory.
# - Appends the target string as "Your review target: <target>".
# - Pipes the result to `codex exec --sandbox read-only --ephemeral`.
# - Codex prints a banner, echoed prompt, and token counts to stdout, so we
#   route the clean final message to a tempfile via `-o` (= `--output-last-message`)
#   and cat that instead.
# - On failure, prints a clearly-labeled diagnostic block (stderr, stdout tail,
#   env). Per-run metadata (timestamp, sizes, exit status) goes to the ground-
#   truth log only, NOT to stdout — keeps the verbatim Codex critique clean.

set -u

# TARGET from $1 if provided, else stdin. The stdin path is what SKILL.md uses
# in practice; it avoids the shell-metacharacter quoting hazards of embedding
# arbitrary user text into a double-quoted bash arg (backticks, $(...), etc.).
if [ $# -ge 1 ]; then
  TARGET="$1"
else
  TARGET=$(cat)
fi

if [ -z "$TARGET" ]; then
  echo "[run_codex.sh: empty TARGET (provide as \$1 or via stdin)]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/critique_prompt.md"

if [ ! -r "$PROMPT_FILE" ]; then
  echo "[run_codex.sh: critique_prompt.md not readable at $PROMPT_FILE]"
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "[codex exec failed: codex not on PATH]"
  exit 1
fi

# Find a writable tempfile path. Default `mktemp` writes to $TMPDIR
# (/var/folders/...) which is sandbox-blocked in some agent runtimes even
# though the literal "$TMPDIR" string appears in the allowlist (the sandbox
# doesn't expand it at allowlist-check time). Try the default first; if it
# fails, fall back to /tmp/claude (mkdir if needed — also sandbox-allowed).
codex_out=$(mktemp 2>/dev/null) || {
  mkdir -p /tmp/claude 2>/dev/null
  codex_out=$(mktemp -p /tmp/claude codex_out.XXXXXX 2>/dev/null)
}

if [ -z "$codex_out" ] || [ ! -w "$codex_out" ]; then
  echo "[codex exec failed: could not create writable tempfile (tried \$TMPDIR and /tmp/claude)]"
  exit 1
fi

# Separate files for codex's stdout and stderr so we can surface error info
# in the fallback message. Some codex error paths print to stdout, not stderr,
# so we need both.
codex_stdout="${codex_out}.stdout"
codex_err="${codex_out}.err"
: > "$codex_stdout"
: > "$codex_err"

trap 'rm -f "$codex_out" "$codex_stdout" "$codex_err"' EXIT

# Hard cap so a hung codex (network stall, auth refresh, etc.) can't hang the
# whole critique skill — and through it, the parent Claude waiting on the
# skill. 10 minutes should be ample for a real critique.
codex_timeout_secs=600  # 10 minutes

# `timeout` is GNU coreutils, not in macOS base. On macOS users typically get
# it as `gtimeout` via `brew install coreutils`. Detect what's available; fall
# back to running codex without a timeout if neither exists (and warn).
#
# Note: the `${TIMEOUT_PREFIX:+...}` expansion below is unquoted intentionally,
# so the embedded space splits "timeout" from the seconds arg. That's only
# safe because the value here is a plain command + integer. If you ever extend
# TIMEOUT_PREFIX with options containing whitespace (e.g.
# `timeout --kill-after=5 600`), switch to a bash array
# (`TIMEOUT_PREFIX=(timeout 600)`) and expand with `"${TIMEOUT_PREFIX[@]}"`
# to avoid the splitting hazard. Array form is set -u safe on bash 4.4+.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_PREFIX="timeout $codex_timeout_secs"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_PREFIX="gtimeout $codex_timeout_secs"
else
  TIMEOUT_PREFIX=""
  echo "[run_codex.sh: no timeout/gtimeout on PATH; running codex unbounded]" >&2
fi

{
  cat "$PROMPT_FILE"
  printf '\n\nYour review target: %s\n' "$TARGET"
} | ${TIMEOUT_PREFIX:+$TIMEOUT_PREFIX} codex exec \
      --sandbox read-only \
      --color never \
      --ephemeral \
      -o "$codex_out" \
      - >"$codex_stdout" 2>"$codex_err"
codex_status=$?

# Ground-truth log: full per-run record (header + content), clobbered each run.
# Lives in /tmp/claude/ rather than ~/.claude/skills/critique/ because the
# agent sandbox that runs this script via bash typically allowlists /tmp/claude
# for writes but blocks writes under ~/.claude/skills/. If we picked the
# skill-dir path, we'd silently lose the log on every sandboxed run — exactly
# the case we most need it for.
#
# Note that parent-Claude has been observed editorializing failure output
# before relaying it, so this log is the only reliable record of what the
# script actually said. Cat this file to see what really happened on the most
# recent run.
RAW_LOG="/tmp/claude/critique-last-codex-output.log"
mkdir -p "$(dirname "$RAW_LOG")" 2>/dev/null

# Write the per-run metadata header to the log only — NOT to stdout. The
# orchestrator relays stdout verbatim into the "## Critique (Codex)" section,
# and any header text would pollute it. Header is useful for post-hoc
# debugging but doesn't belong in the user-facing critique.
{
  echo "[run_codex.sh @ $(date '+%Y-%m-%dT%H:%M:%S %Z')]"
  echo "  target: $TARGET"
  echo "  codex exit status: $codex_status"
  echo "  codex_out size: $(wc -c < "$codex_out" 2>/dev/null || echo 0)"
  echo "  codex_stdout size: $(wc -c < "$codex_stdout" 2>/dev/null || echo 0)"
  echo "  codex_err size: $(wc -c < "$codex_err" 2>/dev/null || echo 0)"
  echo ""
} > "$RAW_LOG"

# Emit content to both stdout (for the orchestrator) and log (for post-hoc).
{
  if [ -s "$codex_out" ]; then
    cat "$codex_out"
  else
    # No output captured. Try to give a specific reason.
    if [ "$codex_status" = "124" ] || [ "$codex_status" = "137" ]; then
      echo "[codex exec failed: timed out after ${codex_timeout_secs}s]"
    else
      echo "[codex exec failed or produced no output (exit $codex_status)]"
    fi
    # Surface both streams. Codex sometimes prints actual errors to stdout
    # (banner + token-counts + auth-error mixed together), so we can't skip it.
    # Tail to keep noise down if codex was verbose before failing.
    if [ -s "$codex_err" ]; then
      echo "---codex stderr---"
      tail -n 50 "$codex_err"
      echo "---/codex stderr---"
    fi
    if [ -s "$codex_stdout" ]; then
      echo "---codex stdout (tail)---"
      tail -n 50 "$codex_stdout"
      echo "---/codex stdout---"
    fi
    # Also surface where codex came from + version, in case PATH/version drift
    # is the cause.
    echo "---codex env---"
    echo "which codex: $(command -v codex 2>&1)"
    echo "codex --version: $(codex --version 2>&1 | head -1)"
    echo "---/codex env---"
  fi
} | tee -a "$RAW_LOG"

# Exit with codex's status so SKILL.md's "exit 1 + sandbox markers → retry"
# trigger works. Tee would otherwise mask the failure with its own exit 0.
if [ -s "$codex_out" ]; then
  exit 0
else
  exit ${codex_status:-1}
fi
