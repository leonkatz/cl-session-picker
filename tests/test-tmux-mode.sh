#!/usr/bin/env bash
# Where the agent runs, and how the non-tmux lifecycle identifies it.
# Run: tests/test-tmux-mode.sh
#
# In iTerm2 the agent must be the tab's OWN process (no tmux) or iTerm's Claude
# Code integration cannot find it. Removing tmux also removes what used to
# answer "is this session live?" and "don't start a second one", so those are
# tested here too — they sit on a kill path.
#
# ISOLATION: every case runs with a fixture $HOME (discovery can only ever see
# fixture sessions) and a fixture PATH whose `claude`, `tmux` and `osascript`
# are fakes. The stop case kills a process this test started, inside a fixture
# HOME, and its "iTerm" is a recording fake — it cannot reach a real session, a
# real tmux server, or a real tab.
#
# Fixtures assert their own preconditions: a setup that failed must FAIL the
# run, never quietly satisfy an assertion that was expecting emptiness.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-mode.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       [%s] not in: %s\n' "$1" "$3" "$2"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then fail=$((fail+1)); printf '  FAIL %s\n       [%s] unexpectedly present\n' "$1" "$3"; else pass=$((pass+1)); printf '  ok   %s\n' "$1"; fi; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }

export HOME="$FIX/home"
SID=aaaaaaaa-1111-2222-3333-444444444444
SID2=bbbbbbbb-1111-2222-3333-444444444444
mkdir -p "$HOME/.claude/projects/p1" "$FIX/work" "$FIX/bin" || setup_failed "mkdir"
printf '{"cwd":"%s"}\n{"customTitle":"Solo"}\n'     "$FIX/work" > "$HOME/.claude/projects/p1/$SID.jsonl"
printf '{"cwd":"%s"}\n{"customTitle":"Solo Two"}\n' "$FIX/work" > "$HOME/.claude/projects/p1/$SID2.jsonl"

cat > "$FIX/bin/claude" <<SH
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done > "$FIX/argv.claude"
exit 0
SH
cat > "$FIX/bin/tmux" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/argv.tmux"
case "\$1" in list-sessions|has-session) exit 1 ;; esac
exit 0
SH
# osascript fake: claims iTerm is running (so tab-closing is exercised) and
# records every script it is handed, including those fed on stdin.
cat > "$FIX/bin/osascript" <<SH
#!/bin/sh
{ printf '== argv: %s\n' "\$*"; cat; } >> "$FIX/osascript.log" 2>/dev/null
echo true
exit 0
SH
chmod +x "$FIX/bin/claude" "$FIX/bin/tmux" "$FIX/bin/osascript" || setup_failed "chmod"
PATHF="$FIX/bin:/usr/bin:/bin:/usr/sbin"

printf 'launch host\n'
run_cl() { local term="$1"; shift; rm -f "$FIX/argv.claude" "$FIX/argv.tmux"
  env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM="$term" "$@" bash "$CL" Solo 2>&1; }
wrapped() { [ -s "$FIX/argv.tmux" ] && grep -q 'new-session' "$FIX/argv.tmux" && echo yes || echo no; }
bare()    { [ -s "$FIX/argv.claude" ] && echo yes || echo no; }

out=$(run_cl "iTerm.app")
check "iTerm: no tmux new-session"        "no"  "$(wrapped)"
check "iTerm: the agent itself is exec'd" "yes" "$(bare)"
has   "iTerm: …on the right session id"   "$(cat "$FIX/argv.claude")" "$SID"
has   "iTerm: the tab is still tagged for cl stop" "$out" "1337;SetUserVar=clSession="
out=$(run_cl "iTerm.app" CL_TMUX=1); check "iTerm + CL_TMUX=1: back in tmux" "yes" "$(wrapped)"
out=$(run_cl "Apple_Terminal");      check "outside iTerm: still tmux"       "yes" "$(wrapped)"

printf 'launch registry — identity for a session with no id in its argv\n'
# Sourced rather than driven end-to-end so the stale and pid-reuse cases can be
# built exactly. Extraction failure aborts instead of vacuously passing.
REGLIB="$FIX/reglib.sh"
{ sed -n '/^tmux_name() {/,/^}/p' "$CL"
  awk '/^PID_DIR=/{f=1} /^session_pid\(\) \{/{f=0} f' "$CL"; } > "$REGLIB"
grep -q '^registered_pid()' "$REGLIB"  || setup_failed "registered_pid not extracted from $CL"
grep -q '^register_launch()' "$REGLIB" || setup_failed "register_launch not extracted from $CL"
# shellcheck disable=SC1090
. "$REGLIB"

register_launch "Solo"
check "registers the calling process" "$$" "$(registered_pid "Solo")"
register_launch "Solo Two"
check "a longer name is a separate record" "$$" "$(registered_pid "Solo Two")"
# The substring trap: matching ps text, `--name Solo` also matched `--name Solo
# Two`, so cl stop could kill the wrong agent. Separate records cannot.
check "'Solo' and 'Solo Two' keep distinct records" "2" \
  "$(ls "$HOME/.config/claude-session/pids" 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$(reg_file 'Solo Two')"

printf '%s\t%s\n' 999999 "Mon Jan  1 00:00:00 2001" > "$(reg_file Dead)"
check "a record whose process is gone yields nothing" "" "$(registered_pid Dead)"
check "…and the stale record is deleted" "0" "$([ -e "$(reg_file Dead)" ] && echo 1 || echo 0)"
printf '%s\t%s\n' "$$" "Mon Jan  1 00:00:00 2001" > "$(reg_file Reused)"
check "a recycled pid (start time differs) yields nothing" "" "$(registered_pid Reused)"
check "…and that record is deleted too" "0" "$([ -e "$(reg_file Reused)" ] && echo 1 || echo 0)"
printf 'x\ty\n' > "$(reg_file Junk)"
check "a non-numeric record never reaches a kill path" "" "$(registered_pid Junk)"
rm -rf "$HOME/.config/claude-session/pids"

printf 'a live session is never launched twice\n'
/bin/sh -c "exec -a 'claude --resume $SID --dangerously-skip-permissions' sleep 45" & LIVE=$!
sleep 0.6
kill -0 "$LIVE" 2>/dev/null || setup_failed "the fixture agent process did not start"
pgrep -f -- "-resume $SID" >/dev/null 2>&1 || setup_failed "fixture agent invisible to pgrep -f — the test would prove nothing"

out=$(env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM=iTerm.app bash "$CL" Solo 2>&1); rc=$?
check "cl <name> on a live session exits 1" "1" "$rc"
has   "…and says why" "$out" "already has a local process"

printf 'cl start opens no tab for a session cl stop left running\n'
mkdir -p "$HOME/.config/claude-session" || setup_failed "mkdir state"
cat > "$HOME/.config/claude-session/state.json" <<JSON
[{"name":"Solo","sid":"$SID","cwd":"$FIX/work","agent":"claude"},
 {"name":"Solo Two","sid":"$SID2","cwd":"$FIX/work","agent":"claude"}]
JSON
: > "$FIX/osascript.log"
out=$(env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM=iTerm.app bash "$CL" start 2>&1)
has   "the live one is reported live" "$out" "Solo already live"
tabs=$(cat "$FIX/osascript.log" 2>/dev/null)
hasnt "…and gets no tab (that would be a 2nd agent on one transcript)" "$tabs" 'cl \"Solo\"'
has   "…while the other session does get its tab" "$tabs" 'cl \"Solo Two\"'

printf 'cl stop kills the intended process and closes its tab\n'
# Incidentally a regression guard for the parent-process check: this file is
# named test-tmux-mode.sh, so the fixture agent's parent command line contains
# "tmux". While that check matched the whole command line it skipped the kill.
kill -0 "$LIVE" 2>/dev/null || setup_failed "fixture agent died before the stop case"
: > "$FIX/osascript.log"
out=$(env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM=iTerm.app bash "$CL" stop </dev/null 2>&1)
sleep 0.5
check "the intended fixture process is gone" "dead" "$(kill -0 "$LIVE" 2>/dev/null && echo alive || echo dead)"
has   "cl stop reported killing it" "$out" "killed Solo"
has   "…and asked iTerm to close its tagged tab" "$(cat "$FIX/osascript.log")" "user.clSession"
hasnt "no tmux server is no longer read as an empty fleet" "$out" "nothing to stop"
kill "$LIVE" 2>/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
