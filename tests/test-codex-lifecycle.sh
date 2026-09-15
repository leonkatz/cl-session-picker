#!/usr/bin/env bash
# `cl stop` / `cl start` for Codex sessions — run: tests/test-codex-lifecycle.sh
#
# The property: cl manages the Codex sessions IT launched, and says so about the
# ones it did not.
#
# That boundary is the point of the file. For Claude, an argv match
# (`--resume <sid>`) is a sound handle. For Codex it is not: threads also run
# through a shared app-server daemon, the Desktop app and --remote clients — none
# of which carry `resume <sid>` in argv — and the npm launcher is a node wrapper
# plus a native child that BOTH match. So the kill path accepts only the launch
# registry (a pid cl recorded, with a start token, under this agent and name),
# while `cl start` deliberately accepts weaker signals, because there a false
# positive costs a reopened tab and a false negative starts a second client on
# one transcript.
#
# ISOLATION: a throwaway HOME, fixture Codex storage, and real sleep processes
# as stand-ins. Nothing signals a process this test did not create.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-codex.XXXXXX")"
cleanup() { [ -n "${VICTIM:-}" ] && kill "$VICTIM" 2>/dev/null; [ -n "${BYSTANDER:-}" ] && kill "$BYSTANDER" 2>/dev/null; rm -rf "$FIX"; }
trap cleanup EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || setup_failed "jq is required by the code under test"

export HOME="$FIX/home"; export CODEX_HOME="$HOME/.codex"
STATE="$HOME/.config/claude-session/state.json"
PIDDIR="$HOME/.config/claude-session/pids"
mkdir -p "$CODEX_HOME/sessions/2026/01/01" "$FIX/work" "$FIX/bin" "$PIDDIR" || setup_failed mkdir

# Two discoverable Codex threads: Mine (cl launched it) and Theirs (it did not).
mk_thread() { # <sid> <name>
  printf '{"id":"%s","thread_name":"%s","updated_at":"2026-01-01T00:00:00Z"}\n' "$1" "$2" >> "$CODEX_HOME/session_index.jsonl"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$1" "$FIX/work" \
    > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$1.jsonl"
}
SID_MINE=01aaaaaa-0000-7000-8000-00000000mine
SID_MINE=01aaaaaa-0000-7000-8000-0000000000aa
SID_THEIRS=01bbbbbb-0000-7000-8000-0000000000bb
mk_thread "$SID_MINE" Mine
mk_thread "$SID_THEIRS" Theirs

# PATH without tmux: the bare/iTerm shape, which is what this is for.
BASEPATH="$FIX/bin:/usr/bin:/bin"
cl() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$BASEPATH" bash "$CL" "$@" ) ; }
# Opening real tabs happens only when the shell is iTerm-hosted; elsewhere cl
# prints the commands instead. Both paths carry the agent, so both are checked.
cl_iterm() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$BASEPATH" \
               TERM_PROGRAM=iTerm.app bash "$CL" "$@" ) ; }

# A real process to stand in for a running agent, and the registry record cl
# would have written when it launched it. Recording the START TOKEN is the whole
# mechanism: it is what proves a pid has not been recycled into something else.
reg_key() { printf '%s\037%s' "$2" "$1" | shasum -a 256 2>/dev/null | cut -c1-40; }
register() { # name agent pid
  local tok; tok=$(ps -o lstart= -p "$3" 2>/dev/null | tr -s ' ' | tr ' ' '_')
  [ -n "$tok" ] || setup_failed "could not read a start token for pid $3"
  printf '%s\t%s\t%s\t%s\n' "$3" "$tok" "$2" "$1" > "$PIDDIR/$(reg_key "$1" "$2")"
}

sleep 600 & VICTIM=$!; disown "$VICTIM" 2>/dev/null || true
# The bystander's command line deliberately LOOKS like a codex resume of the
# thread cl did not launch, so an implementation that fell back to matching argv
# would find and signal it. A plain `sleep` here would survive either way, and
# the assertion below would prove nothing.
/bin/sh -c 'exec -a "codex resume '"$SID_THEIRS"'" sleep 600' & BYSTANDER=$!
disown "$BYSTANDER" 2>/dev/null || true
sleep 0.5
register Mine codex "$VICTIM"
check "fixture: the launch record names the victim" "$VICTIM" \
  "$(cut -f1 "$PIDDIR/$(reg_key Mine codex)")"

printf 'stop: saves and kills the Codex session cl launched\n'
out=$(cl stop --keep-tabs 2>&1)
sleep 1
check "the process cl launched is gone" "dead" \
  "$(kill -0 "$VICTIM" 2>/dev/null && echo alive || echo dead)"
case "$out" in *"killed Mine"*) pass=$((pass+1)); printf '  ok   %s\n' "…and it said so" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and it said so" "$out" ;; esac
check "…it was saved to state first" "Mine" "$(jq -r '.[] | select(.name=="Mine") | .name' "$STATE")"
check "…recorded as a codex session" "codex" "$(jq -r '.[] | select(.name=="Mine") | .agent' "$STATE")"
check "…with its thread id" "$SID_MINE" "$(jq -r '.[] | select(.name=="Mine") | .sid' "$STATE")"
check "…and the launch record is cleared" "0" \
  "$([ -e "$PIDDIR/$(reg_key Mine codex)" ] && echo 1 || echo 0)"

printf 'stop: refuses to guess at a Codex session it did not launch\n'
# THE safety assertion. An argv match could name the node wrapper, the native
# child, an app-server worker, or an unrelated process — so with no launch
# record there is no signal, and nothing is signalled.
check "fixture: an argv match WOULD find the bystander" "1" \
  "$(pgrep -f "codex.* resume $SID_THEIRS( |\$)" 2>/dev/null | grep -c . )"
check "…but it is untouched, because there is no launch record" "alive" \
  "$(kill -0 "$BYSTANDER" 2>/dev/null && echo alive || echo dead)"
case "$out" in *"no launch record"*) pass=$((pass+1)); printf '  ok   %s\n' "…and stop explains why it left it" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and stop explains why it left it" "$out" ;; esac
check "…and it is NOT saved to state" "" "$(jq -r '.[] | select(.name=="Theirs") | .name' "$STATE")"
# Saving it would be worse than useless: `cl start` would later resume a thread
# already open somewhere cl cannot see — two clients on one transcript.

printf 'start: relaunches a Codex session as codex, not as claude\n'
mk_fake() { printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s"\nexit 0\n' "$2" > "$FIX/bin/$1"; chmod +x "$FIX/bin/$1"; }
mk_fake codex  "$FIX/argv.codex"
mk_fake claude "$FIX/argv.claude"
# osascript is handed the script on STDIN, not in argv — a fake that records
# arguments records nothing at all and every assertion below reads empty.
printf '#!/bin/sh\ncat > "%s"\nexit 0\n' "$FIX/osa.txt" > "$FIX/bin/osascript"
chmod +x "$FIX/bin/osascript"
rm -f "$FIX/argv.codex" "$FIX/argv.claude" "$FIX/osa.txt"
# Keep a copy of the state: each start consumes it.
cp "$STATE" "$FIX/state.codex.json"
out_print=$(cl start 2>&1)                       # not iTerm: prints commands
cp "$FIX/state.codex.json" "$STATE"
cl_iterm start >/dev/null 2>&1                   # iTerm: opens tabs
# Bare mode prepares nothing itself — each tab runs `cl <name>`. What start must
# get right is the COMMAND it hands the tab.
OSA="$(cat "$FIX/osa.txt" 2>/dev/null)"
case "$OSA" in *'cl --codex \"Mine\"'*) pass=$((pass+1)); printf '  ok   %s\n' "the tab is told to reopen it as codex" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "the tab is told to reopen it as codex" "$OSA" ;; esac
case "$OSA" in *'cl \"Mine\"'*) fail=$((fail+1)); printf '  FAIL %s\n' "…and never as a bare name (that would resume it as claude)" ;;
  *) pass=$((pass+1)); printf '  ok   %s\n' "…and never as a bare name (that would resume it as claude)" ;; esac
# The printed fallback (no iTerm) has to carry the flag too — it is what the
# user copies by hand, and a bare name there resumes the wrong agent.
case "$out_print" in *'cl --codex "Mine"'*) pass=$((pass+1)); printf '  ok   %s\n' "the printed fallback says --codex too" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "the printed fallback says --codex too" "$out_print" ;; esac

printf 'start: a claude session is unaffected by any of this\n'
printf '[{"name":"Alpha","sid":"abc","cwd":"%s","agent":"claude"}]\n' "$FIX/work" > "$STATE"
rm -f "$FIX/osa.txt"
cl_iterm start >/dev/null 2>&1
OSA="$(cat "$FIX/osa.txt" 2>/dev/null)"
case "$OSA" in *'cl \"Alpha\"'*) pass=$((pass+1)); printf '  ok   %s\n' "a claude row still reopens as a bare name" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "a claude row still reopens as a bare name" "$OSA" ;; esac
case "$OSA" in *'--codex'*) fail=$((fail+1)); printf '  FAIL %s\n' "…with no codex flag" ;;
  *) pass=$((pass+1)); printf '  ok   %s\n' "…with no codex flag" ;; esac

printf 'start: a row with no agent field is treated as claude\n'
# State written by an older version has no agent key. Defaulting it to codex —
# or to empty — would resume every such session with the wrong binary.
printf '[{"name":"Legacy","sid":"xyz","cwd":"%s"}]\n' "$FIX/work" > "$STATE"
rm -f "$FIX/osa.txt"
cl_iterm start >/dev/null 2>&1
OSA="$(cat "$FIX/osa.txt" 2>/dev/null)"
case "$OSA" in *'cl \"Legacy\"'*) pass=$((pass+1)); printf '  ok   %s\n' "an agent-less row reopens as claude" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "an agent-less row reopens as claude" "$OSA" ;; esac

printf 'start: a session that is already live is not opened twice\n'
sleep 600 & LIVE=$!; disown "$LIVE" 2>/dev/null || true
register Live codex "$LIVE"
printf '[{"name":"Live","sid":"%s","cwd":"%s","agent":"codex"}]\n' "$SID_MINE" "$FIX/work" > "$STATE"
rm -f "$FIX/osa.txt"
out=$(cl start 2>&1)
case "$out" in *"Live already live"*) pass=$((pass+1)); printf '  ok   %s\n' "start reports it as already live" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "start reports it as already live" "$out" ;; esac
check "…and opens no tab for it" "0" \
  "$([ -s "$FIX/osa.txt" ] && echo 1 || echo 0)"
kill "$LIVE" 2>/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
