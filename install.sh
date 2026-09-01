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
#   --no-sidebars    skip installing cmux sidebars into ~/.config/cmux/sidebars
#   --no-framework   skip installing framework/*.md into ~/.claude/framework
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
DO_SIDEBARS=1
DO_FRAMEWORK=1
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
    --no-sidebars)  DO_SIDEBARS=0;   shift ;;
    --no-framework) DO_FRAMEWORK=0;  shift ;;
    --bin-dir)      BIN_DIR="$2";    shift 2 ;;
    -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
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
# Step 2b — cmux custom sidebars (only when cmux is installed)
# =============================================================================
# cmux reads sidebars from ~/.config/cmux/sidebars. These complement cl (the
# 'sessions' sidebar groups workspaces by real Claude activity), so install them
# alongside it rather than leaving a manual copy step. Skipped entirely when cmux
# isn't present — cl works fine without it. --no-sidebars opts out.

if [[ "$DO_SIDEBARS" == "1" ]] && command -v cmux >/dev/null 2>&1; then
  SIDEBAR_SRC_DIR="${COMPONENT_DIR}/cmux/sidebars"
  SIDEBAR_DST_DIR="${HOME}/.config/cmux/sidebars"
  if [[ -d "$SIDEBAR_SRC_DIR" ]]; then
    run "mkdir -p '${SIDEBAR_DST_DIR}'"
    for _sb in "$SIDEBAR_SRC_DIR"/*.swift; do
      [[ -e "$_sb" ]] || continue
      _sb_name="$(basename "$_sb")"
      say "installing cmux sidebar ${_sb_name} → ${SIDEBAR_DST_DIR}/"
      run "cp '${_sb}' '${SIDEBAR_DST_DIR}/${_sb_name}'"
    done
    unset _sb _sb_name
    say "  open it with: cmux sidebar open sessions"
  fi
elif [[ "$DO_SIDEBARS" == "1" ]]; then
  say "cmux not found — skipping cmux sidebars (cl works fine without them)"
else
  say "skipping cmux sidebars (--no-sidebars)"
fi

# =============================================================================
# Step 2c — framework procedures → ~/.claude/framework
# =============================================================================
# The generic operating procedures (framework/*.md) are copied so a CLAUDE.md
# can import them with `@~/.claude/framework/<file>`. Copy, not symlink, for
# the same reason as the binary. Deliberately does NOT touch ~/.claude/CLAUDE.md:
# that file is the user's own instantiation, and an installer that edits it
# would be writing content, not scaffolding. --no-framework opts out.
#
# Ownership: the installed copies are package-managed — this step will replace
# them on every rerun. A file that differs from what we ship is backed up
# beside itself first (same rule as the binary), so a local edit is never lost
# silently; but the supported place for customisation is the user's own
# CLAUDE.md beneath the @import, not the installed copy.

if [[ "$DO_FRAMEWORK" == "1" ]]; then
  FRAMEWORK_SRC_DIR="${COMPONENT_DIR}/framework"
  FRAMEWORK_DST_DIR="${HOME}/.claude/framework"
  if [[ -d "$FRAMEWORK_SRC_DIR" ]]; then
    run "mkdir -p '${FRAMEWORK_DST_DIR}'"
    for _fw in "$FRAMEWORK_SRC_DIR"/*.md; do
      [[ -e "$_fw" ]] || continue
      _fw_name="$(basename "$_fw")"
      _fw_dst="${FRAMEWORK_DST_DIR}/${_fw_name}"
      if [[ -e "$_fw_dst" ]] && cmp -s "$_fw" "$_fw_dst"; then
        say "framework ${_fw_name} already current — skipping"
      else
        if [[ -e "$_fw_dst" ]]; then
          # Never overwrite an earlier backup: two reinstalls in one second
          # would otherwise leave only the later edit's copy.
          _fw_bak="${_fw_dst}.bak-${TS}"; _n=1
          while [[ -e "$_fw_bak" ]]; do _fw_bak="${_fw_dst}.bak-${TS}-${_n}"; _n=$((_n+1)); done
          say "framework ${_fw_name} differs from the shipped version — backing up → ${_fw_bak}"
          run "cp '${_fw_dst}' '${_fw_bak}'"
        fi
        say "installing framework ${_fw_name} → ${FRAMEWORK_DST_DIR}/"
        run "cp '${_fw}' '${_fw_dst}'"
      fi
    done
    unset _fw _fw_name _fw_dst _fw_bak _n
    say "  import one into your CLAUDE.md with e.g.:  @~/.claude/framework/when-presenting-a-decision.md"
  fi
else
  say "skipping framework procedures (--no-framework)"
fi

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
# Step 4 — shell wiring: a snippet this installer OWNS, sourced from ~/.zshrc
# =============================================================================
# The PATH + alias content lives in ~/.local/share/claude-session/shellrc — a
# file nothing else writes — and ~/.zshrc carries only a one-line source guard.
# Why: appending real content into ~/.zshrc breaks the moment a dotfiles
# manager replaces that file (2026-09-01: a manager symlinked ~/.zshrc to its
# repo copy and the appended block silently vanished). So:
#   * regular ~/.zshrc → append the guard once, sentinel-marked; an OLD-style
#     block (inline PATH/alias) is migrated to the guard on rerun;
#   * SYMLINKED ~/.zshrc → it belongs to a dotfiles manager; never append
#     through it — print the guard line for the managed file to carry.

SNIPPET_DIR="${HOME}/.local/share/claude-session"
SNIPPET="${SNIPPET_DIR}/shellrc"
SOURCE_GUARD='[ -f "$HOME/.local/share/claude-session/shellrc" ] && source "$HOME/.local/share/claude-session/shellrc"'

run "mkdir -p '${SNIPPET_DIR}'"
_snippet_tmp="$(mktemp)"
{
  printf '# claude-session shell wiring — OWNED by cl-session-picker/install.sh.\n'
  printf '# Rewritten on every install; put your own settings in ~/.zshrc instead.\n'
  printf 'export PATH="%s:$PATH"\n' "${BIN_DIR}"
  printf 'alias cl=%s\n' "${SCRIPT_NAME}"
  printf '# export CL_DEFAULT_DIR="$HOME/your-repo"  # uncomment: dir for  cl new "Name" -d\n'
} > "${_snippet_tmp}"
if [[ -e "$SNIPPET" ]] && cmp -s "${_snippet_tmp}" "$SNIPPET"; then
  say "shell snippet already current: ${SNIPPET}"
else
  say "writing shell snippet → ${SNIPPET}"
  run "cp '${_snippet_tmp}' '${SNIPPET}'"
fi
rm -f "${_snippet_tmp}"

if [[ "$DO_SHELLRC" == "1" ]]; then
  ZSH_SENTINEL="# >>> claude-tools >>>"
  ZSH_SENTINEL_END="# <<< claude-tools <<<"
  if [[ -L "$ZSHRC" ]]; then
    say "NOTE: ${ZSHRC} is a symlink (a dotfiles manager owns it) — not appending."
    say "      Make sure the managed file contains this line:"
    say "        ${SOURCE_GUARD}"
  elif [[ -f "$ZSHRC" ]] && grep -qsF 'claude-session/shellrc' "$ZSHRC"; then
    say "source guard already in ${ZSHRC} — no-op"
  else
    if [[ -f "$ZSHRC" ]]; then
      say "backing up ${ZSHRC} → ${ZSHRC}.bak-${TS}"
      run "cp '${ZSHRC}' '${ZSHRC}.bak-${TS}'"
      if grep -qsF "$ZSH_SENTINEL" "$ZSHRC"; then
        say "migrating old inline claude-tools block to the source guard"
        _zshrc_tmp="$(mktemp)"
        awk -v mark_open="$ZSH_SENTINEL" -v mark_close="$ZSH_SENTINEL_END" '
          $0 == mark_open  { skip = 1; next }
          $0 == mark_close { skip = 0; next }
          !skip { print }
        ' "$ZSHRC" > "${_zshrc_tmp}"
        run "cp '${_zshrc_tmp}' '${ZSHRC}'"
        rm -f "${_zshrc_tmp}"
      fi
    fi
    say "adding the claude-tools source guard to ${ZSHRC}"
    run "printf '\\n%s\\n%s\\n%s\\n' '${ZSH_SENTINEL}' '${SOURCE_GUARD}' '${ZSH_SENTINEL_END}' >> '${ZSHRC}'"
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
