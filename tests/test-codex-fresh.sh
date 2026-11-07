#!/usr/bin/env bash
# Codex `fresh` restart mode — run: tests/test-codex-fresh.sh
#
# A fresh Codex session comes back as a NEW thread under the same name, and it
# must come back as one cl can still own: made through `codex app-server`
# (thread/start, thread/name/set, the name read back), the old thread archived
# BEFORE anything re-arms the coordination lane, the restart row moved onto the
# new id, and then the ordinary `codex resume <new> "<first prompt>"`
# (docs/restart-modes.md, "fresh, for Codex").
#
# Every failure in the first three steps has to land in the same place: the old
# thread resumed plainly, still discoverable under its name, and no row or
# listing pointing at a thread that is not there. So the simulated codex below
# can be told to fail each step, and each case checks all three.
#
# ISOLATION: a fixture HOME and CODEX_HOME, a simulated `codex` on a fixture
# PATH, the suite's own tmux server (TMUX_TMPDIR), and TERM_PROGRAM cleared so
# no tab is ever opened in a real terminal. Nothing here can reach a real
# thread or a real model.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-cxfresh.XXXXXX")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "wanted [$3] in: $2" ;; esac; }
not_contains() { case "$2" in *"$3"*) bad "$1" "did NOT want [$3] in: $2" ;; *) ok "$1" ;; esac; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }
command -v jq      >/dev/null 2>&1 || setup_failed "jq is required by the code under test"
command -v tmux    >/dev/null 2>&1 || setup_failed "tmux hosts the restored sessions"
command -v python3 >/dev/null 2>&1 || setup_failed "python3 runs the simulated codex"

export TERM_PROGRAM=""
export HOME="$FIX/home"; export CODEX_HOME="$HOME/.codex"
STATEDIR="$HOME/.config/claude-session"; STATE="$STATEDIR/state.json"; ROT="$STATEDIR/rotate.json"
export TMUX_TMPDIR="$FIX/tmux-tmp"
rtmux() { TMUX_TMPDIR="$TMUX_TMPDIR" tmux "$@"; }
cleanup() {
  [ -f "$FIX/procs" ] && xargs kill < "$FIX/procs" 2>/dev/null
  # The simulated codex's "TUI" sleeps for a duration nothing else uses, so
  # this reaches only its own.
  pkill -f '^sleep 59.123$' 2>/dev/null
  rtmux kill-server >/dev/null 2>&1
  rm -rf "$FIX" 2>/dev/null || { sleep 0.5; rm -rf "$FIX" 2>/dev/null; }
  return 0
}
trap cleanup EXIT
mkdir -p "$STATEDIR" "$CODEX_HOME/sessions/2026/01/01" "$HOME/.claude/projects/p1" \
         "$FIX/work" "$FIX/bin" "$TMUX_TMPDIR" || setup_failed mkdir

# ── A SIMULATED CODEX ───────────────────────────────────────────────────────
#
# Storage the way Codex 0.163 keeps it, which is all cl reads: an append-only
# session_index.jsonl ({id, thread_name}), a rollout per thread under
# sessions/ whose first line carries the cwd, and archive moving that rollout
# to archived_sessions/. Subcommands:
#
#   app-server   JSON-RPC 2.0 over stdio: initialize, thread/start (writes the
#                rollout, unnamed), thread/name/set (appends an index line),
#                thread/read (reports the name)
#   archive / unarchive <id>
#   resume <id> [prompt]   records its argv, then stays up like a TUI
#
# Every call is appended to $FAKE_CALLS, so the ORDER of the steps is a fact
# the tests can read. FAKE_FAIL picks one failure:
#   start     thread/start answers with an error
#   noreply   thread/start is never answered
#   norollout thread/start answers but writes no rollout
#   name      thread/name/set answers with an error
#   readback  thread/read reports a different name
# FAKE_ARCHIVE_FAIL / FAKE_UNARCHIVE_FAIL name one id whose (un)archive fails;
# FAKE_ARCHIVE_NOOP one whose archive reports success and moves nothing.
cat > "$FIX/fakecodex.py" <<'PYEOF'
import json, os, sys, glob, shutil, time
home = os.environ["CODEX_HOME"]
calls = os.environ.get("FAKE_CALLS", os.devnull)
failure = os.environ.get("FAKE_FAIL", "")
def log(line):
    with open(calls, "a") as fh:
        fh.write(line + "\n")
def rollout(tid, where="sessions"):
    hits = glob.glob(os.path.join(home, where, "**", "rollout-*-%s.jsonl" % tid), recursive=True)
    return hits[0] if hits else None
args = sys.argv[1:]
while args and args[0].startswith("-"):
    args = args[1:]
cmd = args[0] if args else ""
if cmd == "app-server":
    names = {}
    def reply(mid, result=None, error=None):
        msg = {"jsonrpc": "2.0", "id": mid}
        if error is not None:
            msg["error"] = {"code": -32000, "message": error}
        else:
            msg["result"] = result
        sys.stdout.write(json.dumps(msg) + "\n"); sys.stdout.flush()
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        msg = json.loads(raw)
        method = msg.get("method", ""); params = msg.get("params") or {}
        if "id" not in msg:
            log("app-server notify " + method); continue
        log("app-server " + method)
        mid = msg["id"]
        if method == "initialize":
            reply(mid, {"userAgent": "fake", "codexHome": home})
        elif method == "thread/start":
            if failure == "start":
                reply(mid, error="no threads today"); continue
            if failure == "noreply":
                continue
            tid = os.environ.get("FAKE_NEW_ID", "01eeeeee-0000-7000-8000-0000000000ee")
            if failure != "norollout":
                d = os.path.join(home, "sessions", "2026", "02", "02"); os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, "rollout-2026-02-02T00-00-00-%s.jsonl" % tid), "w") as fh:
                    fh.write(json.dumps({"type": "session_meta", "payload": {"id": tid, "cwd": params.get("cwd", "")}}, separators=(",", ":")) + "\n")
            reply(mid, {"thread": {"id": tid, "name": None, "cwd": params.get("cwd")}})
        elif method == "thread/name/set":
            if failure == "name":
                reply(mid, error="cannot name it"); continue
            names[params["threadId"]] = params["name"]
            with open(os.path.join(home, "session_index.jsonl"), "a") as fh:
                fh.write(json.dumps({"id": params["threadId"], "thread_name": params["name"],
                                     "updated_at": "2026-02-02T00:00:00Z"}, separators=(",", ":")) + "\n")
            reply(mid, {})
        elif method == "thread/read":
            name = names.get(params["threadId"])
            if failure == "readback":
                name = "something else"
            reply(mid, {"thread": {"id": params["threadId"], "name": name}})
        else:
            reply(mid, error="unknown method " + method)
    sys.exit(0)
if cmd in ("archive", "unarchive"):
    tid = args[1]
    log("%s %s" % (cmd, tid))
    if os.environ.get("FAKE_%s_FAIL" % cmd.upper()) == tid:
        sys.stderr.write("Error: failed to %s session\n" % cmd); sys.exit(1)
    if cmd == "archive" and os.environ.get("FAKE_ARCHIVE_NOOP") == tid:
        sys.exit(0)
    src = rollout(tid, "sessions" if cmd == "archive" else "archived_sessions")
    if not src:
        sys.stderr.write("Error: failed to %s session\n" % cmd); sys.exit(1)
    if cmd == "archive":
        dest = os.path.join(home, "archived_sessions"); os.makedirs(dest, exist_ok=True)
    else:
        dest = os.path.join(home, "sessions", "2026", "01", "01")
    shutil.move(src, os.path.join(dest, os.path.basename(src)))
    sys.exit(0)
if cmd == "resume":
    log("resume " + " | ".join(args[1:]))
    os.execvp("sleep", ["sleep", "59.123"])
log("other " + " ".join(args))
PYEOF
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$FIX/fakecodex.py" > "$FIX/bin/codex"
chmod +x "$FIX/bin/codex" || setup_failed chmod
ln -sf "$(command -v jq)" "$FIX/bin/jq"
ln -sf "$(command -v tmux)" "$FIX/bin/tmux"
ln -sf "$(command -v python3)" "$FIX/bin/python3"
# The coordination re-arm helper, as a recorder: its line in the call log is
# what "archived BEFORE anything re-arms" is measured against.
printf '#!/bin/sh\necho rearm >> "%s"\necho "no lanes declared"\n' "$FIX/calls" > "$FIX/rearm.sh"
chmod +x "$FIX/rearm.sh"
# A claude stand-in, so a Claude row in the same start launches nothing real.
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> "%s"\nexec sleep 60\n' "$FIX/argv.claude" > "$FIX/bin/claude"
chmod +x "$FIX/bin/claude"

OLD=01aaaaaa-0000-7000-8000-0000000000aa
NEW=01eeeeee-0000-7000-8000-0000000000ee
mk_thread() { # <sid> <name>
  printf '{"id":"%s","thread_name":"%s","updated_at":"2026-01-01T00:00:00Z"}\n' "$1" "$2" >> "$CODEX_HOME/session_index.jsonl"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$1" "$FIX/work" \
    > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$1.jsonl"
}
reset() {
  rtmux kill-server >/dev/null 2>&1
  rm -rf "$CODEX_HOME" "$STATEDIR"/state*.json* "$STATEDIR/history" "$STATEDIR/fresh-history.json" "$FIX/calls" "$FIX/argv.claude"
  mkdir -p "$CODEX_HOME/sessions/2026/01/01"
  mk_thread "$OLD" Gamma
}
write_row() { # <mode>
  printf '[{"name":"Gamma","sid":"%s","cwd":"%s","agent":"codex","mode":"%s"}]\n' "$OLD" "$FIX/work" "$1" > "$STATE"
}
run() { # [VAR=value...] -- <cl args...>
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$FIX/bin:/usr/bin:/bin" TMUX_TMPDIR="$TMUX_TMPDIR" \
      FAKE_CALLS="$FIX/calls" CL_COORD_REARM="$FIX/rearm.sh" CL_HANDOFF_BUDGET=1 CL_CODEX_RPC_TIMEOUT=2 \
      ${envs[@]+"${envs[@]}"} bash "$CL" "$@" 2>&1 )
}
# line_of <pattern>: the call log's first line matching, by number (0 = none).
line_of() { grep -n -- "$1" "$FIX/calls" 2>/dev/null | head -1 | cut -d: -f1 | grep . || echo 0; }
disc_sid() { run -- --discover | awk -F'\t' '$1=="Gamma" && $5=="codex" {print $2}' | head -1; }
active() { [ -n "$(find "$CODEX_HOME/sessions" -name "rollout-*-$1.jsonl" 2>/dev/null)" ] && echo active || echo archived; }
snapshot_sid() { jq -r '.[] | select(.name=="Gamma") | .sid' "$(ls -1t "$STATEDIR"/history/state-*.json 2>/dev/null | head -1)" 2>/dev/null; }
# The id the restored pane was started with, and so the one its CL_SESSION_ID
# and `codex resume` name.
pane_sid() { rtmux list-panes -t "=codex_Gamma:" -F '#{pane_start_command}' 2>/dev/null | grep -oE 'CL_SESSION_ID=[0-9a-f-]+' | head -1 | cut -d= -f2; }

# ── mode storage and the CLI ────────────────────────────────────────────────
echo "cl mode --codex: resume and fresh are accepted, the Claude-only modes are not"
reset; rm -f "$ROT"
out=$(run -- mode --codex Gamma fresh)
contains "fresh is accepted for a Codex session" "$out" 'mode is now fresh for Codex session "Gamma"'
check "…stored in its own section" "fresh" "$(jq -r '.sessions.codex.Gamma' "$ROT")"
check "…and nothing is written for Claude" "null" "$(jq -r '.sessions.claude.Gamma // null' "$ROT")"
check "cl mode --codex <name> shows it, with its layer" '"Gamma" [codex]: fresh (session)' "$(run -- mode --codex Gamma)"
check "--list shows the Codex mode" "fresh" "$(run -- --list | awk '$2=="Gamma"{print $6}' | head -1)"
for m in compact-resume compact handoff on; do
  out=$(run -- mode --codex Gamma "$m"); rc=$?
  check "$m is refused for Codex" "1" "$rc"
done
out=$(run -- mode --codex Gamma handoff)
contains "…saying it is Claude-only" "$out" "Claude-only mode"
check "…and the stored mode is untouched" "fresh" "$(jq -r '.sessions.codex.Gamma' "$ROT")"
check "there is no Codex default to set" "1" "$(run -- mode --codex --default fresh >/dev/null; echo $?)"
check "…and the default is unchanged" "" "$(jq -r '.default // empty' "$ROT")"
check "resume is accepted" "0" "$(run -- mode --codex Gamma resume >/dev/null; echo $?)"
check "…stored as resume" "resume" "$(jq -r '.sessions.codex.Gamma' "$ROT")"
run -- mode --codex Gamma clear >/dev/null
check "clear un-sets it" "null" "$(jq -r '.sessions.codex.Gamma // null' "$ROT")"
check "…and it shows the Codex default" '"Gamma" [codex]: resume (default)' "$(run -- mode --codex Gamma)"
check "the Codex default does not follow a Claude default of compact-resume" "resume" \
  "$(run -- mode --default compact-resume >/dev/null; run -- --list | awk '$2=="Gamma"{print $6}' | head -1)"
check "cl rotate off --codex <name> is resume" "resume" "$(run -- rotate off --codex Gamma >/dev/null; jq -r '.sessions.codex.Gamma' "$ROT")"
check "cl rotate on --codex is still refused" "1" "$(run -- rotate on --codex Gamma >/dev/null; echo $?)"
check "cl rotate clear --codex <name> clears it" "null" "$(run -- rotate clear --codex Gamma >/dev/null; jq -r '.sessions.codex.Gamma // null' "$ROT")"
printf '{"sessions":{"codex":{"Gamma":"handoff"}}}\n' > "$ROT"
check "a hand-edited Claude-only value is not obeyed" "resume" "$(run -- --list 2>/dev/null | awk '$2=="Gamma"{print $6}' | head -1)"
contains "…and status says so" "$(run -- rotate status)" 'Gamma [codex]: ignoring setting "handoff"'
rm -f "$ROT"

# ── cl stop records the mode on the row ─────────────────────────────────────
# The bare (no tmux) shape, with a stand-in client and the launch record cl
# would have written, as in test-codex-lifecycle.sh: stop kills only on that.
reg_key() { printf '%s\037%s' "$2" "$1" | shasum -a 256 2>/dev/null | cut -c1-40; }
stand_in() { # -> starts a process whose argv is `codex resume $OLD`, records it
  /bin/sh -c 'exec -a "codex resume '"$OLD"'" sleep 600' </dev/null >/dev/null 2>&1 &
  local p=$!; disown "$p" 2>/dev/null || true; echo "$p" >> "$FIX/procs"; sleep 0.4
  local tok; tok=$(ps -o lstart= -p "$p" 2>/dev/null | tr -s ' ' | tr ' ' '_')
  [ -n "$tok" ] || setup_failed "start token for $p"
  mkdir -p "$STATEDIR/pids"
  printf '%s\t%s\tcodex\tGamma\t%s\n' "$p" "$tok" "$OLD" > "$STATEDIR/pids/$(reg_key Gamma codex)"
}
NOTMUXPATH="$FIX/notmux"; mkdir -p "$NOTMUXPATH"
ln -sf "$FIX/bin/codex" "$NOTMUXPATH/codex"; ln -sf "$(command -v jq)" "$NOTMUXPATH/jq"
stop_bare() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$NOTMUXPATH:/usr/bin:/bin" \
                  FAKE_CALLS="$FIX/calls" CL_HANDOFF_BUDGET=1 "$@" 2>&1 ); }

echo "cl stop: a fresh Codex session is recorded as fresh, and said so"
reset; rm -f "$ROT"
jq -n '{sessions:{codex:{Gamma:"fresh"}}}' > "$ROT"
stand_in
out=$(stop_bare bash "$CL" stop --dry-run)
contains "the dry run names the Codex mode" "$out" '"Gamma" (codex, mode fresh)'
out=$(stop_bare bash "$CL" stop --keep-tabs)
check "the row says fresh" "fresh" "$(jq -r '.[] | select(.name=="Gamma") | .mode' "$STATE")"
contains "…and the stop says what start will do" "$out" '"Gamma" (codex) is fresh'
check "…and nothing about a stop touches the thread itself" "0" "$(grep -c . "$FIX/calls" 2>/dev/null || echo 0)"
check "a Codex row never enters the rotation log" "0" \
  "$([ -f "$STATEDIR/rotation-log.tsv" ] && awk 'NR>1' "$STATEDIR/rotation-log.tsv" | grep -c . || echo 0)"

echo "cl stop --no-handoff: a fresh Codex session resumes as it was"
reset; stand_in
out=$(stop_bare bash "$CL" stop --keep-tabs --no-handoff)
check "the row says resume" "resume" "$(jq -r '.[] | select(.name=="Gamma") | .mode' "$STATE")"
not_contains "…and nothing says fresh" "$out" "is fresh"

echo "cl stop: a resume-mode Codex session is recorded as resume"
reset; rm -f "$ROT"; stand_in
stop_bare bash "$CL" stop --keep-tabs >/dev/null
check "the row says resume" "resume" "$(jq -r '.[] | select(.name=="Gamma") | .mode' "$STATE")"
rm -f "$ROT"

# ── cl start: the happy path ────────────────────────────────────────────────
echo "cl start: a fresh Codex row comes back as a new, named thread"
reset; write_row fresh
out=$(run -- start); sleep 0.5
contains "start says it made a new thread" "$out" "prepared Gamma as a new Codex thread $NEW"
check "the app-server made the thread" "1" "$([ "$(line_of 'app-server thread/start')" -gt 0 ] && echo 1 || echo 0)"
check "…named it" "1" "$([ "$(line_of 'app-server thread/name/set')" -gt 0 ] && echo 1 || echo 0)"
check "…and read the name back" "1" "$([ "$(line_of 'app-server thread/read')" -gt 0 ] && echo 1 || echo 0)"
contains "the new thread is resumed by id, with a first prompt" "$(cat "$FIX/calls")" "resume $NEW | cl started you as a new thread"
check "the old thread is archived" "archived" "$(active "$OLD")"
check "the name now discovers the new thread" "$NEW" "$(disc_sid)"
check "the pane runs the NEW id (so stop can own it)" "$NEW" "$(pane_sid)"
check "the row was moved onto the new id before it was consumed" "$NEW" "$(snapshot_sid)"
check "…and is consumed" "0" "$([ -f "$STATE" ] && echo 1 || echo 0)"
check "the old id is kept for recovery" "codex" \
  "$(jq -r --arg s "$OLD" '.[] | select(.old_sid==$s) | .agent' "$STATEDIR/fresh-history.json" 2>/dev/null)"
contains "…with the way back" "$out" "codex unarchive $OLD"

echo "the order: archive the old thread, then resume the new one, then re-arm"
a=$(line_of "archive $OLD"); r=$(line_of "resume $NEW"); n=$(line_of 'thread/read'); ra=$(line_of '^rearm')
check "the name is read back before the old thread is archived" "1" "$([ "$n" -gt 0 ] && [ "$n" -lt "$a" ] && echo 1 || echo 0)"
check "archive comes before the resume" "1" "$([ "$a" -gt 0 ] && [ "$a" -lt "$r" ] && echo 1 || echo 0)"
check "archive comes before the re-arm" "1" "$([ "$a" -gt 0 ] && [ "$ra" -gt "$a" ] && echo 1 || echo 0)"

echo "the first prompt comes from the file when there is one"
reset; write_row fresh
printf 'New thread. Read your board.\n' > "$STATEDIR/codex-fresh-prompt.txt"
run -- start >/dev/null; sleep 0.3
contains "the configured prompt is passed" "$(cat "$FIX/calls")" "resume $NEW | New thread. Read your board."
rm -f "$STATEDIR/codex-fresh-prompt.txt"

echo "a resume-mode Codex row is resumed as itself, with no app-server at all"
reset; write_row resume
run -- start >/dev/null; sleep 0.3
check "no thread is made" "0" "$(line_of 'app-server')"
contains "the old thread is resumed by id" "$(cat "$FIX/calls")" "resume $OLD"
not_contains "…with no first prompt" "$(cat "$FIX/calls")" "resume $OLD |"
check "…and nothing is archived" "active" "$(active "$OLD")"

# ── every failure in steps 1-3 resumes the old thread plainly ───────────────
plain_fallback() { # <label>
  contains "$1: it says it is resuming plainly" "$out" "resuming"
  contains "$1: the OLD thread is resumed" "$(cat "$FIX/calls")" "resume $OLD"
  not_contains "$1: …with no first prompt" "$(cat "$FIX/calls")" "resume $OLD |"
  not_contains "$1: the new thread is never resumed" "$(cat "$FIX/calls")" "resume $NEW"
  check "$1: the old thread is still listed" "active" "$(active "$OLD")"
  check "$1: …and the name still discovers it" "$OLD" "$(disc_sid)"
  check "$1: the pane runs the old id" "$OLD" "$(pane_sid)"
  check "$1: the row was left on the old id" "$OLD" "$(snapshot_sid)"
  check "$1: no recovery entry for a rotation that did not happen" "" \
    "$(jq -r '.[]?.old_sid' "$STATEDIR/fresh-history.json" 2>/dev/null)"
}
echo "step 1 failures"
for f in start noreply norollout name readback; do
  reset; write_row fresh
  out=$(run FAKE_FAIL="$f" CL_CODEX_RPC_TIMEOUT=1 -- start); sleep 0.3
  plain_fallback "$f"
  check "$f: the old thread is never archived" "0" "$(line_of "archive $OLD")"
done
# A thread that was made but not used is archived, so two threads never share
# the name (discovery is newest-wins, and the empty one would win).
check "a made-but-unused thread is archived again" "archived" "$(active "$NEW")"

echo "step 2 failure: the old thread cannot be archived"
reset; write_row fresh
out=$(run FAKE_ARCHIVE_FAIL="$OLD" -- start); sleep 0.3
plain_fallback "archive"
contains "archive: it names the failure" "$out" "could not archive its old thread"
check "archive: the new thread is discarded" "archived" "$(active "$NEW")"

echo "step 2 failure: an archive that says it worked, with the thread still listed"
reset; write_row fresh
out=$(run FAKE_ARCHIVE_NOOP="$OLD" -- start); sleep 0.3
contains "noop: it is not taken at its word" "$out" "could not archive its old thread"
contains "noop: the OLD thread is resumed" "$(cat "$FIX/calls")" "resume $OLD"
not_contains "noop: the new thread is never resumed" "$(cat "$FIX/calls")" "resume $NEW"
check "noop: the row was left on the old id" "$OLD" "$(snapshot_sid)"
check "noop: the name still discovers the old thread" "$OLD" "$(disc_sid)"

echo "step 3 failure: the row cannot be moved onto the new thread"
reset; write_row fresh
# A regular file where the row lock goes: the rewrite cannot take the lock.
: > "$STATE.acklock"
out=$(run -- start); sleep 0.3
rm -f "$STATE.acklock"
plain_fallback "row"
contains "row: it names the failure" "$out" "could not move its restart row"
check "row: the old thread was unarchived again" "1" "$([ "$(line_of "unarchive $OLD")" -gt "$(line_of "archive $OLD")" ] && echo 1 || echo 0)"
check "row: the new thread is discarded" "archived" "$(active "$NEW")"

echo "step 3 failure, and the old thread cannot come back either"
reset; write_row fresh; : > "$STATE.acklock"
out=$(run FAKE_UNARCHIVE_FAIL="$OLD" -- start); sleep 0.3
rm -f "$STATE.acklock"
contains "it gives the command to recover it" "$out" "run: codex unarchive $OLD"

echo "a thread something is still running is never archived"
reset; write_row fresh
/bin/sh -c 'exec -a "codex resume '"$OLD"'" sleep 600' </dev/null >/dev/null 2>&1 &
busy=$!; disown "$busy" 2>/dev/null || true; echo "$busy" >> "$FIX/procs"; sleep 0.4
out=$(run -- start); sleep 0.3
kill "$busy" 2>/dev/null
contains "it says why" "$out" "still running here"
check "no thread is made" "0" "$(line_of 'app-server thread/start')"
check "…and the old one is not archived" "active" "$(active "$OLD")"

# ── the bare (no tmux) shape: the tab does it ───────────────────────────────
echo "bare start: the tab command carries the mode and the old id"
reset; write_row fresh
out=$( ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$NOTMUXPATH:/usr/bin:/bin" \
           FAKE_CALLS="$FIX/calls" CL_COORD_REARM="$FIX/rearm.sh" bash "$CL" start 2>&1 ) )
contains "the tab command names the mode and the thread" "$out" "cl --codex \"Gamma\" --restart-mode fresh $OLD"
check "start itself makes nothing — the tab may never run" "0" "$(line_of 'app-server')"
check "…and archives nothing" "active" "$(active "$OLD")"
check "…and keeps the row on the old id" "$OLD" "$(jq -r '.[0].sid' "$STATE")"
tab() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$NOTMUXPATH:/usr/bin:/bin" \
            FAKE_CALLS="$FIX/calls" CL_CODEX_RPC_TIMEOUT=2 "$@" ) >"$FIX/tab.out" 2>&1 & }
tab bash "$CL" --codex Gamma --restart-mode fresh "$OLD"; tp=$!; sleep 3; kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
pkill -f "^sleep 59.123$" 2>/dev/null
contains "the tab resumes the new thread with its first prompt" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
check "…having archived the old one" "archived" "$(active "$OLD")"
check "…and acknowledged its row (moved, then consumed by the launch)" "0" "$([ -f "$STATE" ] && jq length "$STATE" || echo 0)"
echo "bare tab: a tab that runs after the name has moved on resumes, never replaces"
rm -f "$FIX/calls"
tab bash "$CL" --codex Gamma --restart-mode fresh "$OLD"; tp=$!; sleep 2; kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
pkill -f "^sleep 59.123$" 2>/dev/null
contains "it says so" "$(cat "$FIX/tab.out")" "no longer names thread $OLD"
check "no second thread is made" "0" "$(line_of 'app-server')"
contains "…and the current thread is resumed as it is" "$(cat "$FIX/calls")" "resume $NEW"
not_contains "…without a first prompt" "$(cat "$FIX/calls")" "resume $NEW |"
check "a Codex tab refuses a Claude-only mode" "1" \
  "$( ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$NOTMUXPATH:/usr/bin:/bin" bash "$CL" --codex Gamma --restart-mode compact-resume b-1 >/dev/null 2>&1 ); echo $?)"

# ── phase-1 Claude behaviour beside it ──────────────────────────────────────
echo "a Claude row in the same start is untouched by any of this"
reset
printf '{"cwd":"%s"}\n{"customTitle":"Gamma"}\n' "$FIX/work" > "$HOME/.claude/projects/p1/sid-cl.jsonl"
printf '[{"name":"Gamma","sid":"%s","cwd":"%s","agent":"codex","mode":"fresh"},{"name":"Gamma","sid":"sid-cl","cwd":"%s","agent":"claude","resume_only":true,"mode":"fresh"}]\n' \
  "$OLD" "$FIX/work" "$FIX/work" > "$STATE"
out=$(run -- start); sleep 0.5
contains "the Claude row starts a new session by name, as in phase 1" "$(cat "$FIX/argv.claude" 2>/dev/null)" "--name"
not_contains "…not through the app-server" "$(cat "$FIX/argv.claude" 2>/dev/null)" "app-server"
check "…and the Codex row of the same name still got its new thread" "$NEW" "$(disc_sid)"
check "one thread was made, for the Codex row only" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
