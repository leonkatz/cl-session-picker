#!/usr/bin/env bash
# Who does `cl stop` plan for? — run: tests/test-stop-plan.sh
#
# Discovery lists every titled transcript, running or not, and stop used to plan
# for all of them: a session closed weeks ago was "asked" for a handoff it could
# not write and counted in "asking N", while save_state never saved it. Now one
# rule, session_is_live, decides both who is asked and who is saved, so the two
# sets are the same, and closed Claude sessions are named rather than asked.
set -u
CL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-plan.XXXXXX")"
PIDS=""
cleanup() { local p; for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$FIX"; }
trap cleanup EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || setup_failed "jq is required by the code under test"

export HOME="$FIX/home"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$HOME/.claude/projects/p1" "$FIX/work" "$FIX/bin" "$CODEX_HOME/sessions/2026/01/01" || setup_failed mkdir
mk() { printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX/work" "$2" > "$HOME/.claude/projects/p1/$1.jsonl"; }
S1=01a00000-0000-7000-8000-000000000001; S2=01a00000-0000-7000-8000-000000000002
S3=01a00000-0000-7000-8000-000000000003; SX=01c00000-0000-7000-8000-00000000000c
mk "$S1" Open-One; mk "$S2" Open-Two; mk "$S3" Closed-Three
printf '{"id":"%s","thread_name":"Dormant-Codex","updated_at":"2026-01-01T00:00:00Z"}\n' "$SX" > "$CODEX_HOME/session_index.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$SX" "$FIX/work" \
  > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$SX.jsonl"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/claude"; chmod +x "$FIX/bin/claude"

# Two of the three Claude sessions running, found the way a real one is under a
# HOME with no Claude registry: a Claude client (lib-fake-claude.sh) whose
# argv is `--resume <sid>`. Not started inside
# $( ), and with stdio detached, so no command substitution waits on them.
. "$(dirname "$CL")/../tests/lib-fake-claude.sh"
need_fake_claude "$FIX/agentbin/claude"
for s in "$S1" "$S2"; do
  "$FIX/agentbin/claude" --resume "$s" </dev/null >/dev/null 2>&1 &
  PIDS="$PIDS $!"
  # Disowned: stop kills these, and bash would otherwise announce each death
  # ("Terminated: 15") on stderr, where it reads like a failing test.
  disown $! 2>/dev/null || true
done
sleep 0.5

cl() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$FIX/bin:/usr/bin:/bin" \
         TERM_PROGRAM= CL_HANDOFF_BUDGET=1 CL_HANDOFF_TIMEOUT=1 bash "$CL" "$@" ) 2>&1; }

printf 'the plan asks only sessions that are running\n'
out=$(cl stop --dry-run)
check "premise: discovery lists all three Claude sessions" "3" \
  "$(cl --list | grep -cE 'Open-One|Open-Two|Closed-Three')"
check "asking 2, not 3" "1" "$(printf '%s\n' "$out" | grep -c 'asking 2 session(s)')"
check "the two running ones are asked" "2" "$(printf '%s\n' "$out" | grep -cE 'would ask "Open-(One|Two)"')"
check "the closed one is not asked" "0" "$(printf '%s\n' "$out" | grep -c 'would ask "Closed-Three"')"
check "…but is named as not running" "1" "$(printf '%s\n' "$out" | grep -E '^not running' | grep -c 'Closed-Three')"
check "a dormant Codex thread is not mentioned at all" "0" "$(printf '%s\n' "$out" | grep -c 'Dormant-Codex')"

printf 'a real stop saves exactly the sessions it asked\n'
out=$(cl stop --no-handoff --keep-tabs)
STATE="$HOME/.config/claude-session/state.json"
check "saved: the two running sessions, and only those" "Open-One Open-Two" \
  "$(jq -r '[.[].name] | sort | join(" ")' "$STATE" 2>/dev/null)"
check "…and both were stopped" "deaddead" \
  "$(for p in $PIDS; do kill -0 "$p" 2>/dev/null && printf alive || printf dead; done)"

printf 'a session cl could not stop fails the stop\n'
# Exit 0 must mean everything cl manages is stopped (owner decision, 2026-11-03). A
# stand-in that ignores SIGTERM is still running when the shutdown wait ends.
S4=01a00000-0000-7000-8000-000000000004
mk "$S4" Stubborn
"$FIX/agentbin/claude" --ignore-term --resume "$S4" </dev/null >/dev/null 2>&1 &
STUB=$!; PIDS="$PIDS $STUB"; disown "$STUB" 2>/dev/null || true
sleep 0.5
out=$(cl stop --no-handoff --keep-tabs); rc=$?
check "premise: it survived the stop" "alive" "$(kill -0 "$STUB" 2>/dev/null && echo alive || echo dead)"
check "the stop exits non-zero" "1" "$rc"
check "…naming it as left running" "1" "$(printf '%s\n' "$out" | grep -A3 '^left running — declined' | grep -c 'Stubborn')"
kill -9 "$STUB" 2>/dev/null; sleep 0.3
out=$(cl stop --no-handoff --keep-tabs); rc=$?
check "control: once nothing is left running, the stop exits 0" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
