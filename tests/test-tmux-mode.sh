#!/usr/bin/env bash
# Where does the agent actually run? — run: tests/test-tmux-mode.sh
#
# In iTerm2 the agent must be the tab's OWN process (no tmux), or iTerm's
# Claude Code integration cannot find it; everywhere else tmux still wraps it.
# Proven by fake `claude`/`tmux` binaries that record their real argv.
#
# ISOLATION: every case runs with a fixture $HOME (so discovery can only ever
# see fixture sessions) and a fixture PATH whose `claude`, `tmux`, `osascript`
# and `pgrep` are fakes. The stop-path case therefore cannot reach a real
# session, a real tmux server, or a real iTerm tab.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-mode.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       [%s] not found in: %s\n' "$1" "$3" "$2"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then fail=$((fail+1)); printf '  FAIL %s\n       [%s] unexpectedly present\n' "$1" "$3"; else pass=$((pass+1)); printf '  ok   %s\n' "$1"; fi; }

# --- fixture HOME: one named Claude session --------------------------------
export HOME="$FIX/home"
SID=aaaaaaaa-1111-2222-3333-444444444444
mkdir -p "$HOME/.claude/projects/p1" "$FIX/work" "$FIX/bin"
printf '{"cwd":"%s"}\n{"customTitle":"Solo"}\n' "$FIX/work" > "$HOME/.claude/projects/p1/$SID.jsonl"

# --- fixture binaries -------------------------------------------------------
cat > "$FIX/bin/claude" <<SH
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done > "$FIX/argv.claude"
exit 0
SH
cat > "$FIX/bin/tmux" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/argv.tmux"
case "\$1" in
  list-sessions) exit "\${FAKE_TMUX_NOSERVER:-1}" ;;   # default: no server
  has-session)   exit 1 ;;
esac
exit 0
SH
# osascript: neutralises iterm_running / close_iterm_tab so no real tab is touched.
printf '#!/bin/sh\nexit 1\n' > "$FIX/bin/osascript"
chmod +x "$FIX/bin/claude" "$FIX/bin/tmux" "$FIX/bin/osascript"
PATHF="$FIX/bin:/usr/bin:/bin:/usr/sbin"

# run_cl <term-program> <env assignments...> -- <cl args>: returns stdout+stderr
run_cl() {
  local term="$1"; shift
  rm -f "$FIX/argv.claude" "$FIX/argv.tmux"
  env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM="$term" "$@" bash "$CL" Solo 2>&1
}
launched_tmux() { [ -s "$FIX/argv.tmux" ] && grep -q 'new-session' "$FIX/argv.tmux" && echo yes || echo no; }
launched_bare() { [ -s "$FIX/argv.claude" ] && echo yes || echo no; }

printf 'launch host\n'
out=$(run_cl "iTerm.app")
check "iTerm: agent runs bare (no tmux new-session)" "no"  "$(launched_tmux)"
check "iTerm: claude was exec'd directly"            "yes" "$(launched_bare)"
has   "iTerm: …resuming the right session id" "$(cat "$FIX/argv.claude")" "$SID"

out=$(run_cl "iTerm.app" CL_TMUX=1)
check "iTerm + CL_TMUX=1: back inside tmux" "yes" "$(launched_tmux)"

out=$(run_cl "Apple_Terminal")
check "outside iTerm: still tmux"           "yes" "$(launched_tmux)"

printf 'iTerm tab tagging (cl stop closes tabs by this)\n'
out=$(run_cl "iTerm.app")
# OSC 1337 SetUserVar — emitted before exec in BOTH branches, tmux or not.
has  "iTerm no-tmux: tab still tagged with clSession" "$out" "1337;SetUserVar=clSession="

printf 'a `cl new` session (--name in argv, no id) counts as live\n'
# The gap this closes: argv carries --name, never the session id, so the
# id-based match alone reported the newest session as dead.
# The fakes are SYMLINKS to a real interpreter, not #!/bin/sh scripts: a script
# shows argv[0] as /bin/sh in ps, while a real claude shows a path ending in
# `claude` — and argv[0] is exactly what the claude-only guard inspects.
mkdir -p "$FIX/fakeproc"
_interp="$(command -v perl)"
ln -sf "$_interp" "$FIX/fakeproc/claude"
ln -sf "$_interp" "$FIX/fakeproc/dockerd"     # decoy: --name, but not claude
"$FIX/fakeproc/claude"  -e 'sleep 30' -- --name Solo --dangerously-skip-permissions & CLAUDE_PID=$!
"$FIX/fakeproc/dockerd" -e 'sleep 30' -- --name Solo & DECOY_PID=$!
sleep 0.4
list=$(env -i HOME="$HOME" PATH="$FIX/bin:/usr/bin:/bin" TERM_PROGRAM=iTerm.app bash "$CL" --list 2>&1)
has "live marker is ● while the --name process runs" "$list" "● Solo"
kill "$CLAUDE_PID" 2>/dev/null; sleep 0.4
list=$(env -i HOME="$HOME" PATH="$FIX/bin:/usr/bin:/bin" TERM_PROGRAM=iTerm.app bash "$CL" --list 2>&1)
has "…and ○ once it exits, with only the non-claude decoy left" "$list" "○ Solo"
kill "$DECOY_PID" 2>/dev/null

printf 'cl stop no longer mistakes "no tmux server" for "nothing to stop"\n'
# pgrep is faked per-case: the guard must consult it, not just tmux.
printf '#!/bin/sh\nexit 1\n' > "$FIX/bin/pgrep"; chmod +x "$FIX/bin/pgrep"
out=$(env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM=iTerm.app bash "$CL" stop </dev/null 2>&1)
has "no server + no agent: says so and stops" "$out" "nothing to stop"
printf '#!/bin/sh\necho 424242\n' > "$FIX/bin/pgrep"; chmod +x "$FIX/bin/pgrep"
out=$(env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM=iTerm.app bash "$CL" stop </dev/null 2>&1)
hasnt "no server but an agent IS live: does NOT bail" "$out" "nothing to stop"
has   "…it proceeds to save state instead" "$out" "saved"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
