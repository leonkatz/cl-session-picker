#!/usr/bin/env bash
# Which process is running session X? — run: tests/test-session-pid.sh
#
# ── WHAT WENT WRONG ─────────────────────────────────────────────────────────
#
# session_pid answered from argv: `pgrep -f "--resume <sid>" | head -1`.
# `claude --resume P --fork-session` runs a NEW session with its own id, but its
# argv still names the PARENT's id P. So on 2026-10-21 a fork (pid 595) matched
# the parent session, sorted ahead of the real parent (pid 42453) because
# pgrep lists ascending, and `cl stop` would have killed the fork as if it were
# the parent — never asking it for a handoff — while leaving the parent running
# and reporting it stopped. The fork itself was invisible, since its own id
# appears in no argv, so it was neither saved nor restored.
#
# The fix: ask cl's own launch record first, bound to this name AND sid; then
# Claude Code's registry (~/.claude/sessions/<pid>.json), proven by start time;
# then argv, never counting a fork. These tests drive real processes whose argv is shaped exactly like the
# incident, so the fork genuinely matches the parent's id in a pgrep.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-spid.XXXXXX")"
PIDS=""
cleanup() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  rm -rf "$FIX"
}
trap cleanup EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }

LIB="$FIX/lib.sh"
awk '!inf && /^(session_pid|claude_registry_pid|argv_resume_pid|registered_pid|reg_file|start_token|unbound_owner_pid)\(\)/ {
       print; if ($0 ~ /}[[:space:]]*$/) next; inf=1; next }
     inf { print; if ($0 ~ /^}$/) inf=0 }' "$CL" > "$LIB"
for fn in session_pid claude_registry_pid argv_resume_pid registered_pid reg_file start_token unbound_owner_pid; do
  grep -q "^${fn}()" "$LIB" || setup_failed "could not extract ${fn}"
done

# A stand-in agent. NOT `exec sleep`: the process must keep its own argv, since
# argv is precisely what the old lookup read and what the fork lies about.
mkdir -p "$FIX/bin" "$FIX/reg" "$FIX/pids" || setup_failed "mkdir"
cat > "$FIX/bin/claude" <<'SH'
#!/bin/sh
while :; do sleep 1; done
SH
chmod +x "$FIX/bin/claude"

P="11111111-1111-4111-8111-111111111111"   # the parent's session id
F="22222222-2222-4222-8222-222222222222"   # the fork's OWN, new id

# NOT called inside $(...). It sets SPAWNED instead, for two reasons learned the
# hard way: a child started inside a command substitution inherits its pipe, so
# the substitution waits for a process that loops forever (the first run of this
# suite hung exactly that way); and PIDS updated inside $(...) is lost with the
# subshell, so cleanup could never reap what it spawned. stdio is detached for
# the same reason, from whatever the caller happens to be capturing.
# Kill AND reap. A killed background job is otherwise reported by bash the next
# time it checks its jobs ("Terminated: 15"), and a suite writing to stderr reads
# like a failing one.
reap() { local p; for p in "$@"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; }

spawn() {
  "$FIX/bin/claude" "$@" </dev/null >/dev/null 2>&1 &
  SPAWNED=$!; PIDS="$PIDS $SPAWNED"
}
# Write the registry entry exactly as Claude Code does: its pid, its session id,
# and its start time as `ps -o lstart` reads it in UTC.
register() { # pid sid [procStart-override]
  local start="${3:-$(TZ=UTC ps -p "$1" -o lstart= | tr -s ' ' | sed 's/^ //; s/ $//')}"
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","kind":"interactive"}\n' \
    "$1" "$2" "$start" > "$FIX/reg/$1.json"
}
spid() { # sid [name] — with the fixture registry
  ( . "$LIB"; PID_DIR="$FIX/pids"; CL_CLAUDE_SESSIONS_DIR="$FIX/reg"; session_pid "$1" claude "${2:-}" )
}
# Write cl's launch record exactly as the launcher does: pid, start token,
# agent, name, and the sid it is bound to ("-" when unbound, as `cl new` writes).
launch_record() { # pid name sid
  ( . "$LIB"; PID_DIR="$FIX/pids"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$(start_token "$1")" claude "$2" "$3" \
      > "$(reg_file "$2" claude)" )
}
spid_noreg() { # sid [name] — as on a Claude Code too old to keep a registry
  ( . "$LIB"; PID_DIR="$FIX/pids"; CL_CLAUDE_SESSIONS_DIR="$FIX/no-such-dir"; session_pid "$1" claude "${2:-}" )
}

# ── the incident, reproduced ────────────────────────────────────────────────
echo "a fork does not answer for the session it forked from"
# The FORK is started first so it gets the lower pid — the ordering that made
# `pgrep | head -1` pick it on the night.
spawn --resume "$P" --fork-session; FORK=$SPAWNED
spawn --resume "$P"; PARENT=$SPAWNED
sleep 0.5
register "$FORK" "$F"
register "$PARENT" "$P"
# Premises, so nothing below can pass by describing a different situation.
check "the fork's argv really does match the parent's id" "1" \
  "$(pgrep -f "(-resume|-session-id) $P" | grep -cx "$FORK")"
check "…and it has the lower pid, as on the night" "1" \
  "$([ "$FORK" -lt "$PARENT" ] && echo 1 || echo 0)"
check "the old lookup (pgrep | head -1) picks the FORK — the bug" "$FORK" \
  "$(pgrep -f "(-resume|-session-id) $P" | head -1)"

check "session_pid for the parent is the parent" "$PARENT" "$(spid "$P")"
check "session_pid for the fork is the fork — no longer invisible" "$FORK" "$(spid "$F")"

echo "…and without a registry, argv still never hands the parent to a fork"
# A Claude Code without ~/.claude/sessions falls back to argv. The fork must be
# excluded there too, or the bug survives on any older install.
check "argv fallback resolves the parent, not the lower-pid fork" "$PARENT" "$(spid_noreg "$P")"
# The fork's own id appears in no argv, so without a registry it is honestly
# unknown — reported as nothing rather than guessed.
check "…and cannot see the fork's own id, which is the honest answer" "" "$(spid_noreg "$F")"
reap "$PARENT"; sleep 0.3
check "with ONLY the fork running, no source says the parent is live" "" "$(spid_noreg "$P")"
check "…including with the registry" "" "$(spid "$P")"
reap "$FORK"; sleep 0.3

# ── the registry is proof, not a hint ───────────────────────────────────────
echo "a registry entry counts only if the start time proves the process"
spawn --resume "$P"; LIVE=$SPAWNED; sleep 0.5
register "$LIVE" "$P"
check "a matching start time is accepted" "$LIVE" "$(spid "$P")"
# The same pid, a different recorded start: what a stale file looks like once
# its pid has been reused by an unrelated process.
register "$LIVE" "$F" "Mon Jan 1 00:00:00 2001"
check "a mismatched start time is rejected" "" \
  "$( . "$LIB"; CL_CLAUDE_SESSIONS_DIR="$FIX/reg"; claude_registry_pid "$F")"
# A file whose pid is gone entirely is rejected the same way.
printf '{"pid":999999,"sessionId":"%s","procStart":"Mon Jan 1 00:00:00 2001"}\n' "$F" > "$FIX/reg/999999.json"
check "an entry for a dead pid is rejected" "" \
  "$( . "$LIB"; CL_CLAUDE_SESSIONS_DIR="$FIX/reg"; claude_registry_pid "$F")"
rm -f "$FIX/reg/999999.json"
# Unrecognised shape: nothing, never a guess.
printf 'not json\n' > "$FIX/reg/garbage.json"
check "an unreadable entry is ignored, not trusted" "$LIVE" "$(spid "$P")"
rm -f "$FIX/reg/garbage.json"
reap "$LIVE"; rm -f "$FIX/reg"/*.json; sleep 0.3

# ── cl's own launch record outranks the registry ────────────────────────────
echo "a session running twice: cl's record says which copy is cl's"
# Two live processes on the SAME session id — a manual duplicate resume, or a
# race outside cl. Both have valid registry entries, so the registry alone
# would answer with whichever file its glob visits first; `cl stop` would then
# kill the stranger and leave cl's own process running, reported stopped.
spawn --resume "$P"; DUP_A=$SPAWNED
spawn --resume "$P"; DUP_B=$SPAWNED
sleep 0.5
register "$DUP_A" "$P"
register "$DUP_B" "$P"
# The pid the registry glob visits first, and the other one. Owning each in
# turn proves the record wins in BOTH orders, not just the lucky one.
FIRST=$( . "$LIB"; CL_CLAUDE_SESSIONS_DIR="$FIX/reg"; claude_registry_pid "$P")
if [ "$FIRST" = "$DUP_A" ]; then SECOND=$DUP_B; else SECOND=$DUP_A; fi
check "premise: the registry alone answers with one of the two copies" "1" \
  "$([ "$FIRST" = "$DUP_A" ] || [ "$FIRST" = "$DUP_B" ] && echo 1 || echo 0)"
launch_record "$SECOND" Dup "$P"
check "cl owns the copy the registry visits SECOND: that copy is returned" "$SECOND" "$(spid "$P" Dup)"
launch_record "$FIRST" Dup "$P"
check "cl owns the copy the registry visits FIRST: that copy is returned" "$FIRST" "$(spid "$P" Dup)"
# A record bound to a different generation of this name proves nothing about
# this id, so the registry answers instead.
launch_record "$SECOND" Dup "$F"
check "a record bound to another sid is passed over for the registry" "$FIRST" "$(spid "$P" Dup)"
reap "$DUP_A" "$DUP_B"; rm -f "$FIX/reg"/*.json "$FIX/pids"/*; sleep 0.3

echo "without a registry, a same-name record for another sid is not a stop handle"
# `--name` keeps the id out of argv, so the launch record is the only source
# left and nothing else can mask what it decides.
spawn --name Gen; GEN=$SPAWNED; sleep 0.5
launch_record "$GEN" Gen "$P"
check "control: a record bound to this sid resolves it" "$GEN" "$(spid_noreg "$P" Gen)"
launch_record "$GEN" Gen "$F"
check "a record bound to another sid is rejected" "" "$(spid_noreg "$P" Gen)"
reap "$GEN"; rm -f "$FIX/pids"/*; sleep 0.3

# ── a `cl new` launch: unbound record, so the registry answers ──────────────
echo "a session launched by name, with no id in its argv, is still found"
# `cl new` runs `claude --name X`: no id in argv, and its launch record is
# written before the id exists, so it is unbound ("-"). Claude Code's registry
# is what finds it now.
N="33333333-3333-4333-8333-333333333333"
spawn --name Named; NAMED=$SPAWNED; sleep 0.5
launch_record "$NAMED" Named -
register "$NAMED" "$N"
check "the registry resolves it despite the unbound record" "$NAMED" "$(spid "$N" Named)"
# Without a registry it is honestly unknown: an unbound record cannot prove
# which id it runs, and may be a different generation of the name.
check "…and without one, the unbound record is not taken as this id" "" "$(spid_noreg "$N" Named)"
reap "$NAMED"

echo "an unbound owner is surfaced only when nothing can place it"
# unbound_owner_pid is what stops a `cl new` process from reading as "nothing
# live". It must not fire for a process Claude's registry already places on
# some session, or for a record that is bound — those have real answers.
uop() { ( . "$LIB"; PID_DIR="$FIX/pids"; CL_CLAUDE_SESSIONS_DIR="$1"; unbound_owner_pid "$2" ) }
spawn --name Loose; LOOSE=$SPAWNED; sleep 0.5
launch_record "$LOOSE" Loose -
check "unbound, no registry: reported" "$LOOSE" "$(uop "$FIX/no-such-dir" Loose)"
register "$LOOSE" "$F"
check "unbound, but the registry places it: not reported" "" "$(uop "$FIX/reg" Loose)"
register "$LOOSE" "$F" "Mon Jan 1 00:00:00 2001"
check "…a stale registry entry places nothing: reported" "$LOOSE" "$(uop "$FIX/reg" Loose)"
launch_record "$LOOSE" Loose "$P"
check "a bound record is session_pid's to answer: not reported" "" "$(uop "$FIX/no-such-dir" Loose)"
reap "$LOOSE"; sleep 0.3
rm -f "$FIX/reg"/*.json "$FIX/pids"/*

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
