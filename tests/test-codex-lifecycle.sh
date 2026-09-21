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
cleanup() {
  local v
  for v in "${VICTIM:-}" "${BYSTANDER:-}" "${LIVE:-}" "${OLDPROC:-}" "${NOTCODEX:-}" \
           "${WRAP:-}" "${KID:-}" "${CSHARED:-}" "${XSHARED:-}" "${STILLUP:-}"; do
    [ -n "$v" ] && kill "$v" 2>/dev/null
  done
  rm -rf "$FIX"
  return 0
}
trap cleanup EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || setup_failed "jq is required by the code under test"

export HOME="$FIX/home"; export CODEX_HOME="$HOME/.codex"
STATE="$HOME/.config/claude-session/state.json"
PIDDIR="$HOME/.config/claude-session/pids"
mkdir -p "$CODEX_HOME/sessions/2026/01/01" "$HOME/.claude/projects/p1" \
         "$FIX/work" "$FIX/bin" "$PIDDIR" || setup_failed mkdir

# Two discoverable Codex threads: Mine (cl launched it) and Theirs (it did not).
mk_thread() { # <sid> <name> [updated_at]
  # The timestamp matters: discovery is newest-wins, so two threads sharing a
  # name and a timestamp make "which one is current" ambiguous and every
  # assertion downstream becomes a coin toss.
  printf '{"id":"%s","thread_name":"%s","updated_at":"%s"}\n' "$1" "$2" "${3:-2026-01-01T00:00:00Z}" >> "$CODEX_HOME/session_index.jsonl"
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
register() { # name agent pid [sid]
  local tok; tok=$(ps -o lstart= -p "$3" 2>/dev/null | tr -s ' ' | tr ' ' '_')
  [ -n "$tok" ] || setup_failed "could not read a start token for pid $3"
  # Five fields: the record binds the THREAD as well as the agent and name, so
  # a newer same-named thread cannot be saved while the older one is killed.
  printf '%s\t%s\t%s\t%s\t%s\n' "$3" "$tok" "$2" "$1" "${4:--}" > "$PIDDIR/$(reg_key "$1" "$2")"
}

# The stand-in has to LOOK like what it stands in for: stop now revalidates
# that the pid is still running this agent immediately before signalling, so a
# bare `sleep` is correctly refused. A fixture that ignores that tests nothing.
/bin/sh -c 'exec -a "codex resume '"$SID_MINE"'" sleep 600' & VICTIM=$!
disown "$VICTIM" 2>/dev/null || true
sleep 0.5
# The bystander's command line deliberately LOOKS like a codex resume of the
# thread cl did not launch, so an implementation that fell back to matching argv
# would find and signal it. A plain `sleep` here would survive either way, and
# the assertion below would prove nothing.
/bin/sh -c 'exec -a "codex resume '"$SID_THEIRS"'" sleep 600' & BYSTANDER=$!
disown "$BYSTANDER" 2>/dev/null || true
sleep 0.5
register Mine codex "$VICTIM" "$SID_MINE"
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
/bin/sh -c 'exec -a "codex resume '"$SID_MINE"'" sleep 600' & LIVE=$!
disown "$LIVE" 2>/dev/null || true
register Live codex "$LIVE" "$SID_MINE"
printf '[{"name":"Live","sid":"%s","cwd":"%s","agent":"codex"}]\n' "$SID_MINE" "$FIX/work" > "$STATE"
rm -f "$FIX/osa.txt"
out=$(cl start 2>&1)
case "$out" in *"Live already live"*) pass=$((pass+1)); printf '  ok   %s\n' "start reports it as already live" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "start reports it as already live" "$out" ;; esac
check "…and opens no tab for it" "0" \
  "$([ -s "$FIX/osa.txt" ] && echo 1 || echo 0)"
kill "$LIVE" 2>/dev/null

printf 'the launch record names the THREAD, not just the name\n'
# Codex display names are not unique over time: a newer thread with the same
# name wins discovery. A name-only record let stop signal the OLDER thread's
# process while save recorded the NEWER thread's id — stopped process and
# restored transcript would be different sessions.
SID_NEW=01dddddd-0000-7000-8000-0000000000dd
mk_thread "$SID_NEW" Mine 2026-06-01T00:00:00Z   # same display name, NEWER thread
check "fixture: discovery now reports the newer thread for that name" "$SID_NEW" \
  "$(cl --discover 2>/dev/null | awk -F'\t' '$1=="Mine" && $5=="codex" {print $2}' | head -1)"
/bin/sh -c 'exec -a "codex resume '"$SID_MINE"'" sleep 600' & OLDPROC=$!
disown "$OLDPROC" 2>/dev/null || true
sleep 0.5
register Mine codex "$OLDPROC" "$SID_MINE"    # record bound to the OLD thread
rm -f "$STATE"
out=$(cl stop --keep-tabs 2>&1)
sleep 1
check "the old thread's process is not signalled" "alive" \
  "$(kill -0 "$OLDPROC" 2>/dev/null && echo alive || echo dead)"
check "…and the newer thread is not saved on the strength of that record" "" \
  "$(jq -r '.[] | select(.name=="Mine") | .sid' "$STATE" 2>/dev/null)"
kill "$OLDPROC" 2>/dev/null
# Restore a single "Mine" so the sections below are not testing ambiguity.
grep -v "$SID_NEW" "$CODEX_HOME/session_index.jsonl" > "$FIX/idx.tmp" && mv "$FIX/idx.tmp" "$CODEX_HOME/session_index.jsonl"

printf 'a pid that is no longer this agent is not signalled\n'
# The start token proves the pid was not recycled — to the second that ps
# prints. It does not prove what the process IS: a launcher can exec something
# else without changing pid or start time, and the record stays "valid".
rm -f "$PIDDIR"/* "$STATE"
sleep 600 & NOTCODEX=$!                      # a valid pid, wrong program
disown "$NOTCODEX" 2>/dev/null || true
sleep 0.5
register Mine codex "$NOTCODEX" "$SID_MINE"
out=$(cl stop --keep-tabs 2>&1)
sleep 1
check "a pid running something else survives" "alive" \
  "$(kill -0 "$NOTCODEX" 2>/dev/null && echo alive || echo dead)"
case "$out" in *"no longer running codex"*) pass=$((pass+1)); printf '  ok   %s\n' "…and stop says why" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and stop says why" "$out" ;; esac
kill "$NOTCODEX" 2>/dev/null

printf 'a surviving child means the stop is reported incomplete\n'
# The npm launcher is a node wrapper plus a native child. If the wrapper does
# not replace itself, SIGTERM removes the wrapper and the client keeps the
# transcript open — reporting "killed" hands back an untracked session.
rm -f "$PIDDIR"/* "$STATE"
cat > "$FIX/wrapper.sh" <<WRAP
#!/bin/sh
( exec -a "codex child of wrapper" sleep 600 ) &
echo \$! > "$FIX/child.pid"
exec -a "codex wrapper resume $SID_MINE" sleep 600
WRAP
chmod +x "$FIX/wrapper.sh"
"$FIX/wrapper.sh" & WRAP=$!
disown "$WRAP" 2>/dev/null || true
sleep 1
KID="$(cat "$FIX/child.pid" 2>/dev/null)"
check "fixture: the child is a child of the registered pid" "1" \
  "$(pgrep -P "$WRAP" 2>/dev/null | grep -c "^${KID}$")"
register Mine codex "$WRAP" "$SID_MINE"
out=$(cl stop --keep-tabs 2>&1)
sleep 1
check "the wrapper is gone" "dead" "$(kill -0 "$WRAP" 2>/dev/null && echo alive || echo dead)"
check "…the child is still up" "alive" "$(kill -0 "$KID" 2>/dev/null && echo alive || echo dead)"
case "$out" in *"child of it is still running"*) pass=$((pass+1)); printf '  ok   %s\n' "…so stop reports it incomplete, not killed" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…so stop reports it incomplete, not killed" "$out" ;; esac
case "$out" in *"killed Mine"*) fail=$((fail+1)); printf '  FAIL %s\n' "…and never claims it killed it" ;;
  *) pass=$((pass+1)); printf '  ok   %s\n' "…and never claims it killed it" ;; esac
check "…keeping ownership so a retry can finish it" "1" \
  "$([ -e "$PIDDIR/$(reg_key Mine codex)" ] && echo 1 || echo 0)"
kill "$KID" 2>/dev/null

printf 'a tmux session cl did not create is never killed\n'
# A tmux session NAME is derived from the display name and the derivation
# collides, so name equality is not proof of ownership. Only cl's own stamp is.
rm -f "$PIDDIR"/* "$STATE"
mkdir -p "$FIX/tmuxbin"
cat > "$FIX/tmuxbin/tmux" <<TMUXEOF
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/tmux.calls"
case "\$1" in
  has-session)  exit 0 ;;                        # something IS sitting there
  show-option)  [ -f "$FIX/stamped" ] || exit 0  # unstamped: print nothing
                # `tmux show-option -qv -t <target> <option>`: the option name
                # is the FIFTH argument, not the fourth (that is the target).
                case "\$5" in @cl_agent) echo codex ;; @cl_sid) echo "$SID_MINE" ;; esac ;;
esac
exit 0
TMUXEOF
chmod +x "$FIX/tmuxbin/tmux"
cl_tmux() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" \
              PATH="$FIX/tmuxbin:$BASEPATH" bash "$CL" "$@" ) ; }
rm -f "$FIX/tmux.calls" "$FIX/stamped"
out=$(cl_tmux stop --keep-tabs 2>&1)
check "an unstamped tmux session is not killed" "0" \
  "$(grep -c 'kill-session' "$FIX/tmux.calls" 2>/dev/null)"
case "$out" in *"no cl ownership stamp"*) pass=$((pass+1)); printf '  ok   %s\n' "…and stop says why it left it" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and stop says why it left it" "$out" ;; esac
# Not killing it is only half. Saving it would put a restart row in state for a
# session cl does not own — and `cl start` would then resume that thread beside
# whatever is already serving it.
check "…and it is not saved either" "" \
  "$(jq -r '.[] | select(.name=="Mine") | .name' "$STATE" 2>/dev/null)"
# …and one cl did stamp, for this thread, is killed as before.
rm -f "$FIX/tmux.calls" "$STATE"; touch "$FIX/stamped"
out=$(cl_tmux stop --keep-tabs 2>&1)
check "a stamped session IS killed" "1" \
  "$(grep -c 'kill-session' "$FIX/tmux.calls" 2>/dev/null)"
rm -f "$FIX/stamped"

printf 'launching into a name someone else holds does not stamp it\n'
# The stamp is the kill path's only authority, so the launch path must never
# write one onto a session it merely found. `new-session -A` did exactly that:
# it attached an existing session and the helper stamped the result, turning a
# name collision into ownership a later stop would act on.
rm -f "$PIDDIR"/* "$STATE" "$FIX/tmux.calls" "$FIX/stamped"
out=$(cl_tmux --codex Mine 2>&1 || true)
check "no ownership stamp is written" "0" \
  "$(grep -c 'set-option' "$FIX/tmux.calls" 2>/dev/null)"
check "…and nothing new is created" "0" \
  "$(grep -c 'new-session' "$FIX/tmux.calls" 2>/dev/null)"
check "…it attaches what is already there" "1" \
  "$(grep -c 'attach-session' "$FIX/tmux.calls" 2>/dev/null)"
case "$out" in *"cl did not create it"*) pass=$((pass+1)); printf '  ok   %s\n' "…and says so rather than pretending" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and says so rather than pretending" "$out" ;; esac

printf 'same-named Claude and Codex sessions both survive a stop\n'
# The launcher made agent part of session identity; the state union grouped by
# name alone and silently dropped one of them.
rm -f "$PIDDIR"/* "$STATE" "$FIX/tmux.calls"
printf '{"cwd":"%s"}\n{"customTitle":"Shared"}\n' "$FIX/work" > "$HOME/.claude/projects/p1/c-shared.jsonl"
SID_SHARED=01eeeeee-0000-7000-8000-0000000000ee
mk_thread "$SID_SHARED" Shared
/bin/sh -c 'exec -a "claude --resume shared-claude-sid" sleep 600' & CSHARED=$!
/bin/sh -c 'exec -a "codex resume '"$SID_SHARED"'" sleep 600' & XSHARED=$!
disown "$CSHARED" 2>/dev/null || true; disown "$XSHARED" 2>/dev/null || true
sleep 0.5
register Shared claude "$CSHARED"
register Shared codex  "$XSHARED" "$SID_SHARED"
cl stop --keep-tabs >/dev/null 2>&1
sleep 1
check "both rows are in the snapshot" "claude|codex" \
  "$(jq -r '[.[] | select(.name=="Shared") | .agent] | sort | join("|")' "$STATE" 2>/dev/null)"
check "…and both processes were stopped" "dead|dead" \
  "$(kill -0 "$CSHARED" 2>/dev/null && printf alive || printf dead)|$(kill -0 "$XSHARED" 2>/dev/null && printf alive || printf dead)"
kill "$CSHARED" "$XSHARED" 2>/dev/null

printf 'start keeps the rows it skipped instead of consuming them\n'
# agent_live is deliberately optimistic, so a stale signal can drop a session
# from the restart set. Deleting the whole file treated "skipped" as "handled",
# and recovery then required knowing to run cl restore.
rm -f "$PIDDIR"/*
/bin/sh -c 'exec -a "codex resume '"$SID_MINE"'" sleep 600' & STILLUP=$!
disown "$STILLUP" 2>/dev/null || true
sleep 0.5
register Live codex "$STILLUP" "$SID_MINE"
printf '[{"name":"Live","sid":"%s","cwd":"%s","agent":"codex"},{"name":"Gone","sid":"zzz","cwd":"%s","agent":"claude"}]\n' \
  "$SID_MINE" "$FIX/work" "$FIX/work" > "$STATE"
out=$(cl_iterm start 2>&1)
check "the live row is kept for next time" "Live" \
  "$(jq -r '.[].name' "$STATE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
case "$out" in *"left in"*) pass=$((pass+1)); printf '  ok   %s\n' "…and start says so" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and start says so" "$out" ;; esac
kill "$STILLUP" 2>/dev/null
# When nothing is skipped the file is consumed exactly as before.
printf '[{"name":"Gone2","sid":"yyy","cwd":"%s","agent":"claude"}]\n' "$FIX/work" > "$STATE"
cl_iterm start >/dev/null 2>&1
check "a fully-handled start still clears the file" "0" \
  "$([ -f "$STATE" ] && echo 1 || echo 0)"

printf 'a start that fails keeps its row, and a filter failure keeps the file\n'
# Two ways a restart list was lost: a row whose create FAILED was consumed as
# though handled, and a failure while working out what to keep deleted the file
# outright — with archive_state explicitly best-effort, that was the only copy.
rm -f "$PIDDIR"/*
printf '[{"name":"WillFail","sid":"aaa","cwd":"%s","agent":"claude"}]\n' "$FIX/work" > "$STATE"
mkdir -p "$FIX/failbin"
cat > "$FIX/failbin/tmux" <<'TMUXF'
#!/bin/sh
case "$1" in has-session) exit 1 ;; new-session) exit 1 ;; esac
exit 0
TMUXF
chmod +x "$FIX/failbin/tmux"
( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$FIX/failbin:$BASEPATH" \
    CL_TMUX=1 bash "$CL" start >/dev/null 2>&1 )
check "a row whose create failed is kept" "WillFail" \
  "$(jq -r '.[].name' "$STATE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# A failure while working out WHICH rows to keep must not take the list with
# it. Targeted: this jq works for everything except consume_state's own filter,
# so the rest of start behaves normally and only that step fails.
REALJQ="$(command -v jq)"
mkdir -p "$FIX/badjq"
cat > "$FIX/badjq/jq" <<JQF
#!/bin/sh
case "\$*" in *'as \$r'*) exit 1 ;; esac
exec "$REALJQ" "\$@"
JQF
chmod +x "$FIX/badjq/jq"
/bin/sh -c 'exec -a "codex resume '"$SID_MINE"'" sleep 600' & KEEPALIVE=$!
disown "$KEEPALIVE" 2>/dev/null || true
sleep 0.5
register Precious codex "$KEEPALIVE" "$SID_MINE"
printf '[{"name":"Precious","sid":"%s","cwd":"%s","agent":"codex"}]\n' "$SID_MINE" "$FIX/work" > "$STATE"
before="$(cat "$STATE")"
out=$( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$FIX/badjq:$BASEPATH" \
       bash "$CL" start 2>&1 )
check "the restart list survives a filter failure" "same" \
  "$([ -f "$STATE" ] && [ "$before" = "$(cat "$STATE")" ] && echo same || echo LOST)"
case "$out" in *"leaving $STATE as it was"*) pass=$((pass+1)); printf '  ok   %s\n' "…and says it left the file alone" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and says it left the file alone" "$out" ;; esac
kill "$KEEPALIVE" 2>/dev/null

printf 'a stored thread with nothing running is not reported at all\n'
# discover() lists every Codex thread ever named, not the running ones. Warning
# per row means dozens of alarms about history that has no process and no tab —
# the noise that makes a real warning unreadable.
mk_thread 01ffffff-0000-7000-8000-0000000000ff Historical
rm -f "$STATE"
out=$(cl stop --keep-tabs 2>&1)
case "$out" in *Historical*) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "a dormant thread produces no warning" "$out" ;;
  *) pass=$((pass+1)); printf '  ok   %s\n' "a dormant thread produces no warning" ;; esac
check "…and it is not saved either" "" \
  "$(jq -r '.[] | select(.name=="Historical") | .name' "$STATE" 2>/dev/null)"


printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
