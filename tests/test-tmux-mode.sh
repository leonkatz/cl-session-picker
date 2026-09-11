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
  awk '/^PID_DIR=/{f=1} /^session_pid\(\) \{/{f=0} f' "$CL"
  sed -n '/^session_pid() {/,/^}/p' "$CL"; } > "$REGLIB"
for fn in registered_pid acquire_launch reg_file clear_launch session_pid; do
  grep -q "^${fn}()" "$REGLIB" || setup_failed "$fn not extracted from $CL"
done
# shellcheck disable=SC1090
. "$REGLIB"

acquire_launch "Solo" claude || setup_failed "first acquire should succeed"
check "the claim records the calling process" "$$" "$(registered_pid "Solo")"
check "a second claim on a live session is refused" "1" \
  "$(acquire_launch "Solo" claude >/dev/null; echo $?)"

# Names that COLLIDE under tmux_name's sanitiser must not share a record.
# Under tmux `new-session -A` made them one session so two owners could not
# exist; bare, both launch, and a shared record hands one session's pid to the
# other's kill path.
check "tmux_name really does collide on these (the premise)" "same" \
  "$([ "$(tmux_name 'A B')" = "$(tmux_name 'A.B')" ] && echo same || echo differ)"
check "…but their record files differ" "differ" \
  "$([ "$(reg_file 'A B' claude)" != "$(reg_file 'A.B' claude)" ] && echo differ || echo same)"
acquire_launch "A B" claude  || setup_failed "acquire A B"
acquire_launch "A.B" claude  || setup_failed "acquire A.B (must not be blocked by A B)"
check "both colliding names are owned at once" "$$ $$" \
  "$(registered_pid 'A B') $(registered_pid 'A.B')"
clear_launch "A.B"
check "clearing one leaves the other owned" "$$" "$(registered_pid 'A B')"
clear_launch "A B"

# Defence in depth: a record that does not name this session is not trusted
# even if it were found under this key.
printf '%s\t%s\t%s\t%s\n' "$$" "$(ps -o lstart= -p $$ | tr -s ' ')" claude "Someone Else" > "$(reg_file 'Solo Two' claude)"
check "a record naming another session is rejected" "" "$(registered_pid 'Solo Two')"
check "…and deleted" "0" "$([ -e "$(reg_file 'Solo Two' claude)" ] && echo 1 || echo 0)"

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

printf 'acquisition fails CLOSED — an unregisterable session is never launched\n'
# The registry exists so a session is always identifiable. If it cannot record
# ownership, launching anyway produces exactly the invisible session it was
# built to prevent: no duplicate protection, and cl stop may skip it.
rm -rf "$HOME/.config/claude-session/pids"
mkdir -p "$HOME/.config/claude-session" || setup_failed "mkdir config"
chmod 500 "$HOME/.config/claude-session" || setup_failed "chmod config"
rm -f "$FIX/argv.claude"
out=$(env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM=iTerm.app bash "$CL" Solo 2>&1); rc=$?
check "registry dir uncreatable: exits non-zero" "1" "$rc"
check "…and the agent is never reached"          "no" "$(bare)"
has   "…with a specific reason"                  "$out" "refusing to launch"
chmod 700 "$HOME/.config/claude-session" || setup_failed "restore chmod"

mkdir -p "$HOME/.config/claude-session/pids" || setup_failed "mkdir pids"
chmod 500 "$HOME/.config/claude-session/pids" || setup_failed "chmod pids"
rm -f "$FIX/argv.claude"
out=$(env -i HOME="$HOME" PATH="$PATHF" TERM_PROGRAM=iTerm.app bash "$CL" Solo 2>&1); rc=$?
check "record unwritable: exits non-zero" "1" "$rc"
check "…and the agent is never reached"   "no" "$(bare)"
has   "…with a specific reason"           "$out" "refusing to launch"
chmod 700 "$HOME/.config/claude-session/pids" || setup_failed "restore chmod pids"
rm -rf "$HOME/.config/claude-session/pids"

printf 'a held claim is reclaimed only on PROOF the holder is gone\n'
# Age is not proof. A holder merely slow in ps/pgrep/IO must never be displaced,
# or two launchers enter the critical section together.
mkdir -p "$HOME/.config/claude-session/pids" || setup_failed "mkdir pids"
sleep 120 & HOLDER=$!
sleep 0.3
HTOK=$(start_token "$HOLDER")
[ -n "$HTOK" ] || setup_failed "could not read the holder's start token"
HLOCK="$(reg_file 'Held' claude).lock"
ln -s "$HOLDER:$HTOK" "$HLOCK" || setup_failed "could not simulate a held claim"
rm -f "$FIX/acq2.rc"
( acquire_launch "Held" claude >/dev/null 2>&1; echo $? > "$FIX/acq2.rc" ) & ACQ2=$!
sleep 1.5
check "a LIVE holder is not displaced by waiting"   "0"                "$([ -e "$FIX/acq2.rc" ] && echo 1 || echo 0)"
check "…and its lock is untouched"                  "$HOLDER:$HTOK"    "$(readlink "$HLOCK")"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
sleep 1
check "a dead holder IS reclaimed, and the claim succeeds" "0" "$(cat "$FIX/acq2.rc" 2>/dev/null)"
wait "$ACQ2" 2>/dev/null
rm -rf "$HOME/.config/claude-session/pids"

printf 'a non-lock object at the claim path fails closed\n'
# `ln -s target dir` creates the link INSIDE the directory and returns success,
# so a leftover directory there would give a launcher a lock it does not hold
# and mutual exclusion would be silently gone. (Found 2026-09-11 when an older
# mkdir-based fixture left exactly that behind.)
mkdir -p "$HOME/.config/claude-session/pids" || setup_failed "mkdir pids"
STRAY="$(reg_file 'Stray' claude).lock"
mkdir "$STRAY" || setup_failed "could not create the stray directory"
rc=$(acquire_launch "Stray" claude >/dev/null 2>&1; echo $?)
check "a directory at the claim path is refused, not walked into" "2" "$rc"
check "…and nothing was created inside it" "0" "$(find "$STRAY" -mindepth 1 | wc -l | tr -d ' ')"
rmdir "$STRAY" 2>/dev/null
rm -rf "$HOME/.config/claude-session/pids"

printf 'two launchers racing: exactly one reaches the agent (smoke)\n'
# Kept as a smoke test of the whole path, NOT as the atomicity proof — see
# above for that. Both launchers are released from one barrier.
mkdir -p "$FIX/cbin" || setup_failed "mkdir cbin"
cp "$FIX/bin/tmux" "$FIX/bin/osascript" "$FIX/cbin/" || setup_failed "cp fakes"
cat > "$FIX/cbin/claude" <<SH
#!/bin/sh
printf 'launched\n' >> "$FIX/launches.log"
exec sleep 4
SH
chmod +x "$FIX/cbin/claude" || setup_failed "chmod cbin/claude"
rm -rf "$HOME/.config/claude-session/pids"; : > "$FIX/launches.log"; rm -f "$FIX/go"
for i in 1 2; do
  ( until [ -e "$FIX/go" ]; do sleep 0.02; done
    env -i HOME="$HOME" PATH="$FIX/cbin:/usr/bin:/bin:/usr/sbin" TERM_PROGRAM=iTerm.app \
      bash "$CL" "Solo Two" > "$FIX/c$i.out" 2>&1
    echo $? > "$FIX/c$i.rc" ) &
done
sleep 0.4; : > "$FIX/go"; sleep 2
[ -e "$FIX/c1.rc" ] || [ -e "$FIX/c2.rc" ] || setup_failed "neither launcher finished — barrier never released"
check "exactly one launcher reached the agent" "1" "$(grep -c launched "$FIX/launches.log" | tr -d ' ')"
check "the other exited 1"                     "1" "$(cat "$FIX/c1.rc" "$FIX/c2.rc" 2>/dev/null | grep -c '^1$' | tr -d ' ')"
has   "…saying the session is already running" "$(cat "$FIX/c1.out" "$FIX/c2.out" 2>/dev/null)" "already has a local process"
pkill -f 'cbin/claude' 2>/dev/null; wait 2>/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
