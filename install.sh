#!/usr/bin/env bash
# claude-session installer — idempotent; safe to rerun on an already-set-up machine.
#
# Installs the `claude-session` picker (bound to `cl`) plus its dependencies:
#   - copies bin/claude-session into a local bin dir (a real copy, not a symlink,
#     so the installed tool keeps working even if this repo isn't synced)
#   - installs tmux + fzf via Homebrew when missing
#   - enables tmux terminal-title tracking (set-titles on / set-titles-string "#S")
#   - adds the `cl` alias and ensures the bin dir is on PATH
#
# Re-run this after editing bin/claude-session to reinstall the new version.
#
# Optional flags:
#   --dry-run        print actions without executing them
#   --no-deps        skip Homebrew dependency install (tmux, fzf)
#   --no-shellrc     skip ~/.zshrc edits (PATH + `cl` alias)
#   --no-tmux-conf   skip ~/.tmux.conf edits (set-titles options)
#   --bin-dir P      override default install dir (default: ~/.local/bin)
#
# Per Bash standard: [[ ]] for conditionals, printf over echo -e, local for
# function-scoped vars, SCREAMING_SNAKE_CASE for constants. set -euo pipefail is
# used here per explicit installer design requirement (fail-fast is desirable).
set -euo pipefail

# Resolve installer's own directory so it works from any working directory.
COMPONENT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly COMPONENT_DIR

# Defaults — overridable via flags.
BIN_DIR_DEFAULT="$HOME/.local/bin"
readonly ZSHRC="$HOME/.zshrc"
readonly TMUX_CONF="$HOME/.tmux.conf"
readonly SCRIPT_NAME="claude-session"

# Mutable config (set by flag parsing).
DRY_RUN=0
DO_DEPS=1
DO_SHELLRC=1
DO_TMUX_CONF=1
BIN_DIR="$BIN_DIR_DEFAULT"

# Timestamp for backup filenames — one value for the whole run.
TS="$(date +%Y%m%d-%H%M%S)"
readonly TS

# --- Helpers ---

say() {
  printf '%s\n' "$*"
}

# Prints a dry-run notice or executes the given command string.
# All side-effecting operations go through this so --dry-run is reliable.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    say "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1;       shift ;;
    --no-deps)      DO_DEPS=0;       shift ;;
    --no-shellrc)   DO_SHELLRC=0;    shift ;;
    --no-tmux-conf) DO_TMUX_CONF=0;  shift ;;
    --bin-dir)      BIN_DIR="$2";    shift 2 ;;
    -h|--help)      sed -n '2,21p' "$0"; exit 0 ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

# =============================================================================
# Step 1 — Dependencies (tmux required for the experience; fzf for the picker)
# =============================================================================
# The script degrades gracefully without either (tmux: launches claude directly;
# fzf: falls back to a numbered menu), but both are worth having. Installed via
# Homebrew on macOS; on a machine without brew we warn and continue rather than
# fail, since the script still runs in degraded mode.

if [[ "$DO_DEPS" == "1" ]]; then
  if command -v brew >/dev/null 2>&1; then
    for dep in tmux fzf; do
      if command -v "$dep" >/dev/null 2>&1; then
        say "dependency '${dep}' already present — skipping"
      else
        say "installing '${dep}' via Homebrew"
        run "brew install ${dep}"
      fi
    done
  else
    say "WARNING: Homebrew not found — skipping dependency install."
    say "         Install tmux and fzf manually for the full experience:"
    say "           tmux — persistent named sessions"
    say "           fzf  — fuzzy picker (falls back to a numbered menu without it)"
  fi
else
  say "skipping dependency install (--no-deps)"
fi

# =============================================================================
# Step 2 — Install the script into BIN_DIR (real copy, not a symlink)
# =============================================================================
# A copy (not a symlink into this repo) means the installed command keeps working
# even when the repo isn't synced/present. Re-run this installer to pick up edits.

run "mkdir -p '${BIN_DIR}'"

DST="${BIN_DIR}/${SCRIPT_NAME}"
SRC="${COMPONENT_DIR}/bin/${SCRIPT_NAME}"

# Back up an existing copy only when its content differs — avoids churn on reruns.
if [[ -e "$DST" ]] && ! cmp -s "$SRC" "$DST" 2>/dev/null; then
  BACKUP="${DST}.bak-${TS}"
  say "backing up existing ${DST} → ${BACKUP}"
  run "cp '${DST}' '${BACKUP}'"
fi

say "installing ${SCRIPT_NAME} → ${DST}"
run "cp '${SRC}' '${DST}'"
run "chmod +x '${DST}'"

# =============================================================================
# Step 3 — tmux settings in ~/.tmux.conf
# =============================================================================
# Writes, persistently and for ALL tmux usage (not just claude-session):
#   - terminal title follows the session name (#S)
#   - mouse on: trackpad/wheel scrolls into scrollback (copy-mode); without it
#     scroll does nothing on modern tmux
#   - history-limit 50000: default 2000 lines is small for long claude output
# mouse applies to a live server immediately; history-limit only affects panes
# opened after it is set. Idempotent: a sentinel-guarded block is appended once.

if [[ "$DO_TMUX_CONF" == "1" ]]; then
  # NOTE: sentinel strings are frozen identifiers, not branding — they key the
  # managed block in existing dotfiles. Renaming them would make a rerun fail to
  # find the old block and append a duplicate. Leave "claude-tools" as-is.
  TMUX_SENTINEL="# >>> claude-tools: terminal title >>>"
  if [[ -f "$TMUX_CONF" ]] && grep -qsF "$TMUX_SENTINEL" "$TMUX_CONF"; then
    say "tmux settings already in ${TMUX_CONF} — no-op"
  else
    if [[ -f "$TMUX_CONF" ]]; then
      say "backing up ${TMUX_CONF} → ${TMUX_CONF}.bak-${TS}"
      run "cp '${TMUX_CONF}' '${TMUX_CONF}.bak-${TS}'"
    fi
    say "adding tmux settings to ${TMUX_CONF}"
    run "printf '\n%s\nset -g set-titles on\nset -g set-titles-string \"#S\"\nset -g mouse on\nset -g history-limit 50000\n# <<< claude-tools: terminal title <<<\n' '${TMUX_SENTINEL}' >> '${TMUX_CONF}'"
  fi
else
  say "skipping ~/.tmux.conf edits (--no-tmux-conf)"
fi

# =============================================================================
# Step 4 — PATH + `cl` alias in ~/.zshrc
# =============================================================================
# A single sentinel-guarded block carries both the PATH entry (so BIN_DIR is
# reachable) and the `cl` alias. Idempotent on the sentinel.

if [[ "$DO_SHELLRC" == "1" ]]; then
  ZSH_SENTINEL="# >>> claude-tools >>>"
  if [[ -f "$ZSHRC" ]] && grep -qsF "$ZSH_SENTINEL" "$ZSHRC"; then
    say "claude-tools block already in ${ZSHRC} — no-op"
  else
    if [[ -f "$ZSHRC" ]]; then
      say "backing up ${ZSHRC} → ${ZSHRC}.bak-${TS}"
      run "cp '${ZSHRC}' '${ZSHRC}.bak-${TS}'"
    fi
    say "adding PATH entry and 'cl' alias to ${ZSHRC}"
    run "printf '\n%s\nexport PATH=\"%s:\$PATH\"\nalias cl=%s\n# <<< claude-tools <<<\n' '${ZSH_SENTINEL}' '${BIN_DIR}' '${SCRIPT_NAME}' >> '${ZSHRC}'"
  fi
else
  say "skipping ~/.zshrc edits (--no-shellrc)"
fi

# =============================================================================
# Done
# =============================================================================

say ""
say "done."
say ""
say "next steps:"
say "  1. source ${ZSHRC}   (or open a new terminal)"
say "  2. run 'cl'          to open the session picker"
say "  3. run 'cl --list'   to see discovered named sessions"
