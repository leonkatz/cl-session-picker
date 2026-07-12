#!/usr/bin/env bash
# claude-session uninstaller — reverses install.sh; idempotent and safe to rerun.
#
# Removes:
#   - the claude-session binary from the local bin dir
#   - the sentinel-guarded block from ~/.zshrc  (PATH entry + `cl` alias)
#   - the sentinel-guarded block from ~/.tmux.conf (set-titles / mouse / history)
#
# Deliberately LEFT in place (remove manually if you want them gone):
#   - Homebrew deps (tmux, fzf, jq) — general-purpose tools you may still want
#   - your session state + history in ~/.config/claude-session/ — that's your
#     data. Pass --purge-state to delete it too.
#
# Optional flags:
#   --dry-run        print actions without executing them
#   --no-shellrc     leave ~/.zshrc untouched
#   --no-tmux-conf   leave ~/.tmux.conf untouched
#   --purge-state    also delete ~/.config/claude-session (state.json + history)
#   --bin-dir P      look for the binary in P (default: ~/.local/bin)
#
# Per Bash standard: [[ ]] for conditionals, printf over echo -e, local for
# function-scoped vars, SCREAMING_SNAKE_CASE for constants. set -euo pipefail is
# used here per explicit installer/uninstaller design requirement (fail-fast).
set -euo pipefail

# Defaults — overridable via flags.
BIN_DIR_DEFAULT="$HOME/.local/bin"
readonly ZSHRC="$HOME/.zshrc"
readonly TMUX_CONF="$HOME/.tmux.conf"
readonly SCRIPT_NAME="claude-session"
readonly STATE_DIR="$HOME/.config/claude-session"

# The sentinel markers install.sh writes. These are FROZEN identifiers — they
# must match install.sh exactly, or the block won't be found and removed.
readonly ZSH_OPEN="# >>> claude-tools >>>"
readonly ZSH_CLOSE="# <<< claude-tools <<<"
readonly TMUX_OPEN="# >>> claude-tools: terminal title >>>"
readonly TMUX_CLOSE="# <<< claude-tools: terminal title <<<"

# Mutable config (set by flag parsing).
DRY_RUN=0
DO_SHELLRC=1
DO_TMUX_CONF=1
PURGE_STATE=0
BIN_DIR="$BIN_DIR_DEFAULT"

TS="$(date +%Y%m%d-%H%M%S)"
readonly TS

# --- Helpers ---

say() {
  printf '%s\n' "$*"
}

# Prints a dry-run notice or executes the given command string. All side-effecting
# operations go through this so --dry-run is reliable.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    say "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

# remove_block <file> <open-sentinel> <close-sentinel>
# Deletes the inclusive range between the sentinels (fixed-string matched, since
# the markers contain regex-special chars). No-op with a notice if absent. Backs
# up the file before rewriting. Uses a temp file + mv so a failure can't truncate.
remove_block() {
  local file="$1" open="$2" close="$3"
  if [[ ! -f "$file" ]]; then
    say "  ${file} does not exist — nothing to remove"
    return 0
  fi
  if ! grep -qsF "$open" "$file"; then
    say "  no claude-session block in ${file} — nothing to remove"
    return 0
  fi
  say "  backing up ${file} → ${file}.bak-${TS}"
  run "cp '${file}' '${file}.bak-${TS}'"
  say "  removing claude-session block from ${file}"
  # awk skips the open..close range inclusive; everything else is preserved.
  run "awk -v s='${open}' -v e='${close}' 'index(\$0,s){skip=1} !skip{print} index(\$0,e){skip=0}' '${file}' > '${file}.tmp.\$\$' && mv '${file}.tmp.\$\$' '${file}'"
}

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1;       shift ;;
    --no-shellrc)   DO_SHELLRC=0;    shift ;;
    --no-tmux-conf) DO_TMUX_CONF=0;  shift ;;
    --purge-state)  PURGE_STATE=1;   shift ;;
    --bin-dir)      BIN_DIR="$2";    shift 2 ;;
    -h|--help)      sed -n '2,26p' "$0"; exit 0 ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

# =============================================================================
# Step 1 — Remove the installed binary
# =============================================================================

DST="${BIN_DIR}/${SCRIPT_NAME}"
say "removing ${SCRIPT_NAME} binary"
if [[ -e "$DST" ]]; then
  say "  ${DST}"
  run "rm -f '${DST}'"
else
  say "  not found at ${DST} — nothing to remove"
fi

# =============================================================================
# Step 2 — Remove the ~/.zshrc block (PATH + `cl` alias)
# =============================================================================

if [[ "$DO_SHELLRC" == "1" ]]; then
  say "cleaning ${ZSHRC}"
  remove_block "$ZSHRC" "$ZSH_OPEN" "$ZSH_CLOSE"
else
  say "skipping ~/.zshrc (--no-shellrc)"
fi

# =============================================================================
# Step 3 — Remove the ~/.tmux.conf block (set-titles / mouse / history-limit)
# =============================================================================

if [[ "$DO_TMUX_CONF" == "1" ]]; then
  say "cleaning ${TMUX_CONF}"
  remove_block "$TMUX_CONF" "$TMUX_OPEN" "$TMUX_CLOSE"
else
  say "skipping ~/.tmux.conf (--no-tmux-conf)"
fi

# =============================================================================
# Step 4 — Optionally purge session state + history
# =============================================================================
# Off by default: this is the user's data (saved session lists + rotating
# history). Only removed when explicitly requested.

if [[ "$PURGE_STATE" == "1" ]]; then
  if [[ -d "$STATE_DIR" ]]; then
    say "purging session state + history at ${STATE_DIR}"
    run "rm -rf '${STATE_DIR}'"
  else
    say "no session state at ${STATE_DIR} — nothing to purge"
  fi
else
  if [[ -d "$STATE_DIR" ]]; then
    say "leaving session state at ${STATE_DIR} (pass --purge-state to delete it)"
  fi
fi

# =============================================================================
# Done
# =============================================================================

say ""
say "done."
say ""
say "notes:"
say "  - Homebrew deps (tmux, fzf, jq) were left installed; remove with 'brew uninstall' if unwanted."
say "  - open a new terminal (or 'source ${ZSHRC}') so the 'cl' alias stops resolving."
