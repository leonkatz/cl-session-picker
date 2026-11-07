#!/usr/bin/env bash
# Codex `fresh` restart mode — run: tests/test-codex-fresh.sh
#
# A fresh Codex session comes back as a NEW thread under the same name, and it
# must come back as one cl can still own: made through `codex app-server`
# (thread/start, thread/name/set, the name read back), the old thread archived
# — on the tmux path, BEFORE anything re-arms the coordination lane; in the
# bare-iTerm shape the re-arm comes first and the election heals on the new
# thread's first SessionStart — the restart row moved onto the new id, and then
# the ordinary `codex resume <new> "<first prompt>"` (docs/restart-modes.md,
# "fresh, for Codex").
#
# The swap is a persisted transaction (one file per name, phase by phase, under
# a per-name claim): a failure before the archive rolls back to the old thread;
# from the archive on, a retry — even after the whole cl process group was
# killed at a boundary — carries the same new thread forward, and the row is
# settled only once the launch is verified as codex on the new id.
#
# Every failure BEFORE the archive has to land in the same place: the old
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
command -v cc      >/dev/null 2>&1 || setup_failed "cc builds the stand-in codex executable (Xcode command line tools)"

export TERM_PROGRAM=""
export HOME="$FIX/home"; export CODEX_HOME="$HOME/.codex"
STATEDIR="$HOME/.config/claude-session"; STATE="$STATEDIR/state.json"; ROT="$STATEDIR/rotate.json"
export TMUX_TMPDIR="$FIX/tmux-tmp"
rtmux() { TMUX_TMPDIR="$TMUX_TMPDIR" tmux "$@"; }
kill_stubs() { [ -f "$FIX/stub.pids" ] && xargs kill < "$FIX/stub.pids" 2>/dev/null; rm -f "$FIX/stub.pids"; return 0; }
cleanup() {
  [ -f "$FIX/procs" ] && xargs kill < "$FIX/procs" 2>/dev/null
  # The simulated codex's "TUI" sleeps for a duration nothing else uses, so
  # this reaches only its own.
  kill_stubs
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
# FAKE_STUBBORN=1: the app-server ignores SIGTERM and outlives EOF on stdin.
# FAKE_COLLIDE=1: before answering thread/start, the server sends a REQUEST of
# its own that happens to carry the same id.
# Each app-server writes its pid to $FAKE_SERVER_PIDS.
# FAKE_CRASH_AT=name|read|archive: SIGKILL the whole cl process group (its
# leader's pid is in $FAKE_CRASH_PGID_FILE) on receiving thread/name/set, on
# receiving thread/read, or just after moving the old rollout — a crash at
# that boundary, with nothing left to clean up after itself.
# FAKE_CRASH_AT=start-early|start-created: the crash at thread/start, before
# the thread is written, or after it is written and before the reply — the
# window in which cl cannot have recorded the new id.
# FAKE_ARCHIVE_LIES=<id>: archive moves it, then reports failure (a lost reply).
# FAKE_ARCHIVE_VANISH=<id>: archive removes it from sessions/ without putting
# it in archived_sessions/, and reports failure — a result nobody can read.
# FAKE_SLOW_START=<s>: thread/start answers after that long.
cat > "$FIX/fakecodex.py" <<'PYEOF'
import json, os, sys, glob, shutil, time, signal
def crash(at):
    if os.environ.get("FAKE_CRASH_AT") != at:
        return
    log("crash " + at)
    with open(os.environ["FAKE_CRASH_PGID_FILE"]) as fh:
        os.killpg(int(fh.read().strip()), signal.SIGKILL)
    sys.exit(0)
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
    import signal
    with open(os.environ.get("FAKE_SERVER_PIDS", os.devnull), "a") as fh:
        fh.write("%d\n" % os.getpid())
    if os.environ.get("FAKE_STUBBORN"):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
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
        if method == "thread/name/set":
            crash("name")
        if method == "thread/read":
            crash("read")
        if method == "thread/start" and os.environ.get("FAKE_SLOW_START"):
            time.sleep(float(os.environ["FAKE_SLOW_START"]))
        if method == "initialize":
            reply(mid, {"userAgent": "fake", "codexHome": home})
        elif method == "thread/start":
            if failure == "start":
                reply(mid, error="no threads today"); continue
            if failure == "noreply":
                continue
            if os.environ.get("FAKE_COLLIDE"):
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "method": "item/tool/requestUserInput",
                                             "params": {"threadId": "x"}}) + "\n"); sys.stdout.flush()
                time.sleep(0.5)
            tid = os.environ.get("FAKE_NEW_ID") or open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "new_id")).read().strip()
            crash("start-early")
            if failure != "norollout":
                d = os.path.join(home, "sessions", "2026", "02", "02"); os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, "rollout-2026-02-02T00-00-00-%s.jsonl" % tid), "w") as fh:
                    fh.write(json.dumps({"type": "session_meta", "payload": {"id": tid, "cwd": params.get("cwd", ""),
                                                                              "thread_source": params.get("threadSource")}}, separators=(",", ":")) + "\n")
            crash("start-created")
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
            # From the index, like Codex's own store: a later app-server must
            # see a name an earlier one set.
            name = None
            for line in open(os.path.join(home, "session_index.jsonl")):
                rec = json.loads(line)
                if rec.get("id") == params["threadId"]:
                    name = rec.get("thread_name")
            if failure == "readback":
                name = "something else"
            reply(mid, {"thread": {"id": params["threadId"], "name": name}})
        else:
            reply(mid, error="unknown method " + method)
    if os.environ.get("FAKE_STUBBORN"):
        while True:
            time.sleep(1)
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
    if cmd == "archive" and os.environ.get("FAKE_ARCHIVE_VANISH") == tid:
        os.remove(src); sys.exit(1)
    shutil.move(src, os.path.join(dest, os.path.basename(src)))
    if cmd == "archive" and os.environ.get("FAKE_ARCHIVE_LIES") == tid:
        sys.stderr.write("Error: timed out\n"); sys.exit(1)
    if cmd == "archive" and tid == os.environ.get("FAKE_CRASH_ARCHIVE_ID"):
        crash("archive")
    sys.exit(0)
if cmd == "resume":
    log("resume " + " | ".join(args[1:]))
    if os.environ.get("FAKE_RESUME_DIES"):
        sys.exit(1)
    if os.environ.get("FAKE_RESUME_NOT_CODEX"):
        # A pane that stays up running something else: a wrapper, an error
        # screen. Pane lifetime is not an agent.
        os.execvp("sleep", ["sleep", "59.124"])
    # Stays up looking like what it stands in for: launch verification looks
    # for `codex … resume <id>` inside the pane, as the kill path does.
    os.execv(os.path.join(os.path.dirname(os.path.abspath(__file__)), "stub", "codex"), ["codex", "resume"] + args[1:])
log("other " + " ".join(args))
PYEOF
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$FIX/fakecodex.py" > "$FIX/bin/codex"
# The simulated codex's "TUI" has to BE a codex executable: launch acceptance
# reads the kernel's record of the process (proc_pidpath, KERN_PROCARGS2), so
# a renamed argv[0] is not enough. A compiled stub named codex is: its real
# path ends in /codex, and its argv is whatever it was exec'd with. It records
# its pid so cleanup kills exactly these, never anything matched by name.
mkdir -p "$FIX/stub"
cat > "$FIX/stub/stub.c" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
  const char *f = getenv("FAKE_STUB_PIDS");
  if (f) { FILE *o = fopen(f, "a"); if (o) { fprintf(o, "%d\n", (int)getpid()); fclose(o); } }
  sleep(59);
  return 0;
}
CEOF
cc -o "$FIX/stub/codex" "$FIX/stub/stub.c" 2>/dev/null || setup_failed "could not build the stand-in codex"
chmod +x "$FIX/bin/codex" || setup_failed chmod
ln -sf "$(command -v jq)" "$FIX/bin/jq"
# tmux itself, except that FAKE_TMUX_REFUSE makes new-session fail: the one
# way to reach "steps 1-3 done, then the launch refused".
REALTMUX="$(command -v tmux)"
# FAKE_TMUX_CRASH=before|after kills the cl process group just before, or
# just after, the launch — a crash after the row write, and after the launch.
cat > "$FIX/bin/tmux" <<TMUXEOF
#!/bin/sh
[ -n "\${FAKE_TMUX_REFUSE:-}" ] && [ "\$1" = "new-session" ] && exit 1
if [ "\$1" = "new-session" ] && [ "\${FAKE_TMUX_CRASH:-}" = "before" ]; then
  echo "crash before-launch" >> "\$FAKE_CALLS"; kill -9 -- -"\$(cat "\$FAKE_CRASH_PGID_FILE")"; exit 1
fi
if [ "\$1" = "new-session" ] && [ "\${FAKE_TMUX_CRASH:-}" = "after" ]; then
  "$REALTMUX" "\$@"; rc=\$?
  sleep 0.3
  echo "crash after-launch" >> "\$FAKE_CALLS"; kill -9 -- -"\$(cat "\$FAKE_CRASH_PGID_FILE")"; exit \$rc
fi
exec "$REALTMUX" "\$@"
TMUXEOF
chmod +x "$FIX/bin/tmux"
ln -sf "$(command -v python3)" "$FIX/bin/python3"
# The coordination re-arm helper, as a recorder: its line in the call log is
# what "archived BEFORE anything re-arms" is measured against.
printf '#!/bin/sh\necho rearm >> "%s"\necho "no lanes declared"\n' "$FIX/calls" > "$FIX/rearm.sh"
chmod +x "$FIX/rearm.sh"
# A claude stand-in, so a Claude row in the same start launches nothing real.
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> "%s"\nexec sleep 60\n' "$FIX/argv.claude" > "$FIX/bin/claude"
chmod +x "$FIX/bin/claude"

# Ids unique to this run. The liveness checks are machine-wide (`codex …
# resume <id>` anywhere on the box), and other suites run stand-ins with fixed
# ids — a shared id would make their processes look like this thread running.
RUN_TAG=$(printf '%06x%06x' "$(( $$ & 0xffffff ))" "$(( RANDOM * 32768 + RANDOM ))" | cut -c1-12)
OLD=01aaaaaa-0000-7000-8000-$RUN_TAG
NEW=01eeeeee-0000-7000-8000-$RUN_TAG
printf '%s\n' "$NEW" > "$FIX/new_id"
mk_thread() { # <sid> <name>
  printf '{"id":"%s","thread_name":"%s","updated_at":"2026-01-01T00:00:00Z"}\n' "$1" "$2" >> "$CODEX_HOME/session_index.jsonl"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$1" "$FIX/work" \
    > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$1.jsonl"
}
reset() {
  rtmux kill-server >/dev/null 2>&1
  kill_stubs
  pkill -f '^sleep 59\.124$' 2>/dev/null
  rm -rf "$CODEX_HOME" "$STATEDIR"/state*.json* "$STATEDIR/history" "$STATEDIR/fresh-history.json" "$FIX/calls" "$FIX/argv.claude" \
         "$STATEDIR/codex-fresh" "$STATEDIR/pids"
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
      FAKE_CALLS="$FIX/calls" FAKE_STUB_PIDS="$FIX/stub.pids" CL_COORD_REARM="$FIX/rearm.sh" CL_HANDOFF_BUDGET=1 CL_CODEX_RPC_TIMEOUT=2 \
      ${envs[@]+"${envs[@]}"} bash "$CL" "$@" 2>&1 )
}
# line_of <pattern>: the call log's first line matching, by number (0 = none).
line_of() { grep -n -- "$1" "$FIX/calls" 2>/dev/null | head -1 | cut -d: -f1 | grep . || echo 0; }
disc_sid() { run -- --discover | awk -F'\t' '$1=="Gamma" && $5=="codex" {print $2}' | head -1; }
active() { [ -n "$(find "$CODEX_HOME/sessions" -name "rollout-*-$1.jsonl" 2>/dev/null)" ] && echo active || echo archived; }
snapshot_sid() { jq -r '.[] | select(.name=="Gamma") | .sid' "$(ls -1t "$STATEDIR"/history/state-*.json 2>/dev/null | head -1)" 2>/dev/null; }
# The id the restored pane was started with, and so the one its CL_SESSION_ID
# and `codex resume` name.
# poll_until <tenths> <shell-condition>: wait for a milestone, generously.
poll_until() { local n=0; until eval "$2" || [ "$n" -ge "$1" ]; do sleep 0.1; n=$((n+1)); done; }
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
                  FAKE_CALLS="$FIX/calls" FAKE_STUB_PIDS="$FIX/stub.pids" CL_HANDOFF_BUDGET=1 "$@" 2>&1 ); }

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

echo "a launch refused after the swap keeps it pending, and a re-run resumes NEW with no third thread"
reset; write_row fresh
out=$(run FAKE_TMUX_REFUSE=1 -- start); sleep 0.3
contains "the refused launch is reported" "$out" "could not prepare Gamma"
check "the kept row names the new thread" "$NEW" "$(jq -r '.[0].sid' "$STATE" 2>/dev/null)"
check "…still pending, not finished" "fresh" "$(jq -r '.[0].mode' "$STATE" 2>/dev/null)"
check "…with its cycle named" "1" "$(jq -r '.[0].fresh_pending // empty' "$STATE" 2>/dev/null | grep -c .)"
check "…keeping the old id as fresh_from" "$OLD" "$(jq -r '.[0].fresh_from' "$STATE" 2>/dev/null)"
contains "the old id's way back is printed" "$out" "codex unarchive $OLD"
check "…and recorded" "codex" \
  "$(jq -r --arg s "$OLD" '.[] | select(.old_sid==$s) | .agent' "$STATEDIR/fresh-history.json" 2>/dev/null)"
rm -f "$FIX/calls"
out=$(run -- start); sleep 0.3
check "the re-run makes no thread" "0" "$(line_of 'app-server')"
check "…archives nothing" "0" "$(line_of '^archive')"
check "…leaves the new thread listed" "active" "$(active "$NEW")"
contains "…and resumes the new thread, its first turn still to come" "$(cat "$FIX/calls")" "resume $NEW | cl started you"

echo "an app-server that ignores TERM and outlives EOF cannot hang the start"
reset; write_row fresh; rm -f "$FIX/server.pids"
( run FAKE_STUBBORN=1 FAKE_SERVER_PIDS="$FIX/server.pids" -- start > "$FIX/stub.out" ) &
sp=$!; w=0
while kill -0 "$sp" 2>/dev/null && [ "$w" -lt 150 ]; do sleep 0.1; w=$((w+1)); done
check "the start finished within 15s" "done" "$(kill -0 "$sp" 2>/dev/null && echo hung || echo done)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
contains "…and still made the new thread" "$(cat "$FIX/stub.out")" "as a new Codex thread $NEW"
spid=$(head -1 "$FIX/server.pids" 2>/dev/null)
[ -n "$spid" ] || setup_failed "the stubborn server recorded no pid"
check "…and the server was killed" "gone" "$(kill -0 "$spid" 2>/dev/null && echo alive || echo gone)"
kill -9 "$spid" 2>/dev/null

echo "a server request that reuses a pending id is not taken for the reply"
reset; write_row fresh
out=$(run FAKE_COLLIDE=1 -- start); sleep 0.3
contains "thread/start is still learned" "$out" "as a new Codex thread $NEW"
check "…and the old thread is archived" "archived" "$(active "$OLD")"

echo "an interrupt while the app-server is open leaves no clrpc directory"
reset; write_row fresh; rm -f "$FIX/server.pids"
mkdir -p "$FIX/tmpdir"
set -m
( cd "$FIX" && exec env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$FIX/bin:/usr/bin:/bin" TMUX_TMPDIR="$TMUX_TMPDIR" \
    TMPDIR="$FIX/tmpdir" FAKE_CALLS="$FIX/calls" FAKE_STUB_PIDS="$FIX/stub.pids" FAKE_FAIL=noreply FAKE_SERVER_PIDS="$FIX/server.pids" \
    CL_COORD_REARM="$FIX/rearm.sh" CL_CODEX_RPC_TIMEOUT=30 bash "$CL" start ) >/dev/null 2>&1 &
ip=$!
set +m
disown "$ip" 2>/dev/null || true
w=0; until ls "$FIX/tmpdir" 2>/dev/null | grep -q '^clrpc\.' || [ "$w" -ge 100 ]; do sleep 0.1; w=$((w+1)); done
check "fixture: the app-server directory exists while it is open" "1" "$(ls "$FIX/tmpdir" | grep -c '^clrpc\.')"
sleep 0.5
kill -TERM -- -"$ip" 2>/dev/null
w=0; while kill -0 "$ip" 2>/dev/null && [ "$w" -lt 50 ]; do sleep 0.1; w=$((w+1)); done
sleep 1
check "the directory is removed" "0" "$(ls "$FIX/tmpdir" | grep -c '^clrpc\.')"
spid=$(head -1 "$FIX/server.pids" 2>/dev/null)
check "…and the server is gone" "gone" "$( [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && echo alive || echo gone)"
check "…and nothing was archived" "active" "$(active "$OLD")"
kill -9 "$spid" -- -"$ip" 2>/dev/null

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
# After the archive the transaction only rolls forward: nothing is launched
# now, nothing is unarchived, and the next start finishes the same thread.
contains "row: it names the failure" "$out" "could not move its restart row"
not_contains "row: nothing is launched" "$(cat "$FIX/calls")" "resume "
check "row: nothing is unarchived" "0" "$(line_of 'unarchive')"
check "row: the old thread stays archived" "archived" "$(active "$OLD")"
check "row: the new thread stays listed" "active" "$(active "$NEW")"
check "row: the way back is recorded" "$OLD" "$(jq -r '.[0].old_sid' "$STATEDIR/fresh-history.json" 2>/dev/null)"
check "row: the row is kept" "1" "$(jq length "$STATE" 2>/dev/null)"
out=$(run -- start); sleep 0.3
contains "row: the re-run carries the replacement on" "$out" "carrying on its pending replacement"
check "row: …making no second thread" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
contains "row: …and runs the new thread" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
check "row: …and the replacement is finished" "0" "$(ls "$STATEDIR/codex-fresh" 2>/dev/null | grep -c '\.json$')"

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
           FAKE_CALLS="$FIX/calls" FAKE_STUB_PIDS="$FIX/stub.pids" CL_COORD_REARM="$FIX/rearm.sh" bash "$CL" start 2>&1 ) )
contains "the tab command names the mode and the thread" "$out" "cl --codex \"Gamma\" --restart-mode fresh $OLD"
check "start itself makes nothing — the tab may never run" "0" "$(line_of 'app-server')"
check "…and archives nothing" "active" "$(active "$OLD")"
check "…and keeps the row on the old id" "$OLD" "$(jq -r '.[0].sid' "$STATE")"
tab() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$NOTMUXPATH:/usr/bin:/bin" \
            FAKE_CALLS="$FIX/calls" FAKE_STUB_PIDS="$FIX/stub.pids" CL_CODEX_RPC_TIMEOUT=2 "$@" ) >"$FIX/tab.out" 2>&1 & }
# Polled for its milestone, never a fixed sleep: the launcher's speed varies
# by machine, and killing it early is what the assertions would then measure.
tab bash "$CL" --codex Gamma --restart-mode fresh "$OLD"; tp=$!
poll_until 300 "grep -q 'resume $NEW' '$FIX/calls' 2>/dev/null && [ \"\$(jq -r .phase '$STATEDIR'/codex-fresh/*.json 2>/dev/null)\" = launching ]"
kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
contains "the tab resumes the new thread with its first prompt" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
check "…having archived the old one" "archived" "$(active "$OLD")"
check "…and its row is NOT consumed: exec cannot see the agent start" "$NEW" "$(jq -r '.[0].sid' "$STATE" 2>/dev/null)"
check "…so the replacement is still pending" "launching" "$(jq -r '.phase' "$STATEDIR"/codex-fresh/*.json 2>/dev/null)"
out=$( ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$NOTMUXPATH:/usr/bin:/bin" \
           FAKE_CALLS="$FIX/calls" FAKE_STUB_PIDS="$FIX/stub.pids" CL_COORD_REARM="$FIX/rearm.sh" bash "$CL" start 2>&1 ) )
contains "the next start verifies it and says so" "$out" "Gamma is running on its new Codex thread $NEW"
check "…finishing the replacement" "0" "$(ls "$STATEDIR/codex-fresh" 2>/dev/null | grep -c '\.json$')"
check "…and consuming the row" "0" "$([ -f "$STATE" ] && jq length "$STATE" || echo 0)"
kill_stubs
echo "bare tab: a tab that runs after the name has moved on resumes, never replaces"
rm -f "$FIX/calls"
tab bash "$CL" --codex Gamma --restart-mode fresh "$OLD"; tp=$!
poll_until 300 "grep -q 'no longer names' '$FIX/tab.out' 2>/dev/null && grep -q 'resume $NEW' '$FIX/calls' 2>/dev/null"
kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
kill_stubs
contains "it says so" "$(cat "$FIX/tab.out")" "no longer names thread $OLD"
check "no second thread is made" "0" "$(line_of 'app-server')"
contains "…and the current thread is resumed as it is" "$(cat "$FIX/calls")" "resume $NEW"
not_contains "…without a first prompt" "$(cat "$FIX/calls")" "resume $NEW |"
check "a Codex tab refuses a Claude-only mode" "1" \
  "$( ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$NOTMUXPATH:/usr/bin:/bin" bash "$CL" --codex Gamma --restart-mode compact-resume b-1 >/dev/null 2>&1 ); echo $?)"

# ── crashes at each boundary, then a retry ──────────────────────────────────
# Each case kills the whole cl process group at one boundary (nothing gets to
# clean up), then runs an ordinary `cl start`. The retry must carry on the SAME
# replacement: one thread made in total, the new one run, never a plain resume
# of an archived old thread.
crash_start() { # <VAR=value...>: a start in its own process group, killed by the fixture
  rm -f "$FIX/pgid"
  set -m
  ( cd "$FIX" && exec env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$FIX/bin:/usr/bin:/bin" TMUX_TMPDIR="$TMUX_TMPDIR" \
      FAKE_CALLS="$FIX/calls" FAKE_STUB_PIDS="$FIX/stub.pids" FAKE_CRASH_PGID_FILE="$FIX/pgid" CL_COORD_REARM="$FIX/rearm.sh" CL_HANDOFF_BUDGET=1 \
      CL_CODEX_RPC_TIMEOUT=5 "$@" bash "$CL" start ) >"$FIX/crash.out" 2>&1 &
  local cp=$!
  set +m
  disown "$cp" 2>/dev/null || true
  echo "$cp" > "$FIX/pgid"
  local w=0; while kill -0 "$cp" 2>/dev/null && [ "$w" -lt 150 ]; do sleep 0.1; w=$((w+1)); done
  kill -9 -- -"$cp" 2>/dev/null
  sleep 0.3
  # A killed start leaves its claim; cl refuses to take it over (see the
  # abandoned-claim test) and prints the command below. Each crash case runs
  # it, as the operator would, so the retry is about the transaction.
  rm -f "$STATEDIR"/codex-fresh/*.lock 2>/dev/null
}
txn_phase() { jq -r '.phase // empty' "$STATEDIR"/codex-fresh/*.json 2>/dev/null; }
retry_finishes() { # <label>
  rm -f "$FIX/calls.before"; cp "$FIX/calls" "$FIX/calls.before" 2>/dev/null
  out=$(run -- start); sleep 0.3
  check "$1: one thread made in total" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
  contains "$1: the retry runs the new thread" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
  not_contains "$1: …never the old one" "$(cat "$FIX/calls")" "resume $OLD"
  check "$1: the old thread is archived" "archived" "$(active "$OLD")"
  check "$1: the name discovers the new thread" "$NEW" "$(disc_sid)"
  check "$1: the replacement is finished" "" "$(txn_phase)"
  check "$1: the way back is recorded once" "1" "$(jq --arg s "$OLD" '[.[] | select(.old_sid==$s)] | length' "$STATEDIR/fresh-history.json" 2>/dev/null)"
}
echo "crash after create (at the name step), then a retry"
reset; write_row fresh
crash_start FAKE_CRASH_AT=name
contains "fixture: it crashed there" "$(cat "$FIX/calls")" "crash name"
check "the new id was written down before the crash" "$NEW" "$(jq -r '.new_sid' "$STATEDIR"/codex-fresh/*.json 2>/dev/null)"
check "…at phase created" "created" "$(txn_phase)"
check "…with the old thread untouched" "active" "$(active "$OLD")"
retry_finishes "after create"

echo "…and a retry whose naming fails rolls back, the old thread untouched"
reset; write_row fresh
crash_start FAKE_CRASH_AT=name
out=$(run FAKE_FAIL=name -- start); sleep 0.3
contains "it says it is resuming plainly" "$out" "resuming it plainly"
check "the unnamed new thread is discarded" "archived" "$(active "$NEW")"
check "the old thread is still listed" "active" "$(active "$OLD")"
contains "…and resumed" "$(cat "$FIX/calls")" "resume $OLD"
check "the journal is gone" "" "$(txn_phase)"

echo "…but not when the old thread is no longer listed: nothing is discarded"
reset; write_row fresh
crash_start FAKE_CRASH_AT=name
mkdir -p "$CODEX_HOME/archived_sessions"
mv "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$OLD.jsonl" "$CODEX_HOME/archived_sessions/"
out=$(run FAKE_FAIL=name -- start); sleep 0.3
contains "it refuses to roll back" "$out" "not rolling back"
check "the new thread is kept" "active" "$(active "$NEW")"
not_contains "nothing is launched" "$(cat "$FIX/calls")" "resume "
check "the journal stays" "created" "$(txn_phase)"

echo "crash after name (at the read-back), then a retry"
reset; write_row fresh
crash_start FAKE_CRASH_AT=read
contains "fixture: it crashed there" "$(cat "$FIX/calls")" "crash read"
check "the replacement is pending at created" "created" "$(txn_phase)"
retry_finishes "after name"

echo "crash after archive, then a retry"
reset; write_row fresh
crash_start FAKE_CRASH_AT=archive FAKE_CRASH_ARCHIVE_ID="$OLD"
contains "fixture: it crashed there" "$(cat "$FIX/calls")" "crash archive"
check "the old thread is archived" "archived" "$(active "$OLD")"
check "the replacement is pending, its new id known" "$NEW" "$(jq -r '.new_sid' "$STATEDIR"/codex-fresh/*.json 2>/dev/null)"
check "…and the row still names the old thread" "$OLD" "$(jq -r '.[0].sid' "$STATE")"
retry_finishes "after archive"

echo "crash after the row write (before launch), then a retry"
reset; write_row fresh
crash_start FAKE_TMUX_CRASH=before
contains "fixture: it crashed there" "$(cat "$FIX/calls")" "crash before-launch"
check "the row names the new thread" "$NEW" "$(jq -r '.[0].sid' "$STATE")"
check "…still pending" "fresh" "$(jq -r '.[0].mode' "$STATE")"
check "the replacement is at rewritten" "rewritten" "$(txn_phase)"
retry_finishes "after row write"

echo "crash after launch (before it was verified), then a retry"
reset; write_row fresh
crash_start FAKE_TMUX_CRASH=after
contains "fixture: it crashed there" "$(cat "$FIX/calls")" "crash after-launch"
check "the row is not consumed" "$NEW" "$(jq -r '.[0].sid' "$STATE" 2>/dev/null)"
out=$(run -- start); sleep 0.3
contains "the retry adopts the unstamped session its start launched" "$out" "adopting the tmux session"
contains "the retry verifies the running thread" "$out" "Gamma is running on its new Codex thread $NEW"
check "…launching nothing again" "1" "$(grep -c "resume $NEW" "$FIX/calls")"
check "…making no second thread" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
check "…and finishing the replacement" "" "$(txn_phase)"
check "…and consuming the row" "0" "$([ -f "$STATE" ] && jq length "$STATE" || echo 0)"

echo "a launch that does not come up as codex on the new id is not settled"
reset; write_row fresh
out=$(run FAKE_RESUME_DIES=1 CL_RESUME_CHECK=1 -- start); sleep 0.3
contains "it says it could not confirm" "$out" "could not confirm codex is running on its new thread"
check "the row stays on the new thread" "$NEW" "$(jq -r '.[0].sid' "$STATE" 2>/dev/null)"
check "…still pending" "fresh" "$(jq -r '.[0].mode' "$STATE" 2>/dev/null)"
check "the replacement stays, at launching" "launching" "$(txn_phase)"
rtmux kill-server >/dev/null 2>&1
out=$(run -- start); sleep 0.3
check "the retry makes no second thread" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
check "…and finishes it this time" "" "$(txn_phase)"

echo "a pane that stays up without codex on the new id is not settled either"
reset; write_row fresh
out=$(run FAKE_RESUME_NOT_CODEX=1 CL_RESUME_CHECK=1 -- start); sleep 0.3
check "fixture: the pane is up" "1" "$(rtmux list-sessions 2>/dev/null | grep -c '^codex_Gamma')"
contains "it is not taken for the agent" "$out" "could not confirm codex is running on its new thread"
check "the replacement stays pending" "launching" "$(txn_phase)"
rtmux kill-server >/dev/null 2>&1

# ── two starts at once ──────────────────────────────────────────────────────
echo "a second cl start while one is replacing the thread does not run its own swap"
reset; write_row fresh
( run FAKE_SLOW_START=2 CL_CODEX_RPC_TIMEOUT=6 -- start > "$FIX/first.out" ) &
first=$!
w=0; until grep -q 'app-server thread/start' "$FIX/calls" 2>/dev/null || [ "$w" -ge 100 ]; do sleep 0.1; w=$((w+1)); done
second=$(run CL_FRESH_CLAIM_WAIT=1 -- start)
wait "$first" 2>/dev/null; sleep 0.3
contains "the second start leaves it to the first" "$second" "another cl start"
check "only one thread is made" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
check "only one archive of the old thread" "1" "$(grep -c "^archive $OLD" "$FIX/calls")"
contains "the first start finished the replacement" "$(cat "$FIX/first.out")" "as a new Codex thread $NEW"
check "the name discovers the new thread" "$NEW" "$(disc_sid)"

echo "a second start that waits out the first finds the row already handled"
reset; write_row fresh
( run FAKE_SLOW_START=1 CL_CODEX_RPC_TIMEOUT=6 -- start > "$FIX/first.out" ) &
first=$!
w=0; until grep -q 'app-server thread/start' "$FIX/calls" 2>/dev/null || [ "$w" -ge 100 ]; do sleep 0.1; w=$((w+1)); done
second=$(run CL_FRESH_CLAIM_WAIT=20 -- start)
wait "$first" 2>/dev/null; sleep 0.3
check "only one thread is made" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
contains "the second sees it was done meanwhile" "$second" "was started by another cl start meanwhile"
check "the name discovers the new thread" "$NEW" "$(disc_sid)"

echo "a claim left by a cl that died is refused, with the command that clears it"
reset; write_row fresh
mkdir -p "$STATEDIR/codex-fresh"
key=$(printf 'codex\037%s' Gamma | shasum -a 256 | cut -c1-40)
ln -s "999999:not-a-real-start-token" "$STATEDIR/codex-fresh/$key.json.lock"
out=$(run -- start); sleep 0.3
contains "it refuses, saying why" "$out" "left its claim on this replacement"
check "nothing is made" "0" "$(line_of 'app-server')"
check "the claim is left exactly where it was" "999999:not-a-real-start-token" "$(readlink "$STATEDIR/codex-fresh/$key.json.lock")"
contains "it says how to check nothing is still working on it" "$out" "ps -p 999999 -o lstart=,command="
recovery=$(printf '%s\n' "$out" | sed -n 's/^    \(\[ "$(readlink .*\)$/\1/p' | head -1)
contains "the removal is conditional on that exact holder" "$recovery" "999999:not-a-real-start-token"
# The condition is the safety: run against a claim that has since changed hands,
# it removes nothing.
ln -sfn "12345:someone-alive" "$STATEDIR/codex-fresh/$key.json.lock"
eval "$recovery" || :
check "…so it removes nothing once the claim names someone else" "12345:someone-alive" "$(readlink "$STATEDIR/codex-fresh/$key.json.lock")"
ln -sfn "999999:not-a-real-start-token" "$STATEDIR/codex-fresh/$key.json.lock"
eval "$recovery"
check "…and removes it while it still names the dead holder" "0" "$([ -L "$STATEDIR/codex-fresh/$key.json.lock" ] && echo 1 || echo 0)"
out=$(run -- start); sleep 0.3
contains "after it, the swap is carried out" "$out" "as a new Codex thread $NEW"

# ── names shared, and other threads in the repo ─────────────────────────────
echo "other threads — one with the same name, one in the same repo — are left alone"
reset
OLDER=01bbbbbb-0000-7000-8000-$RUN_TAG; DELTA=01cccccc-0000-7000-8000-$RUN_TAG
mk_thread "$OLDER" Gamma; touch -t 202001010000 "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$OLDER.jsonl"
mk_thread "$DELTA" Delta
write_row fresh
out=$(run -- start); sleep 0.3
check "the row's thread is the one archived" "archived" "$(active "$OLD")"
check "the older same-named thread is untouched" "active" "$(active "$OLDER")"
check "the other thread in the repo is untouched" "active" "$(active "$DELTA")"
check "only the row's thread was archived" "1" "$(grep -c '^archive ' "$FIX/calls")"
check "the name discovers the new thread" "$NEW" "$(disc_sid)"
check "Delta is still discovered as itself" "$DELTA" "$(run -- --discover | awk -F'\t' '$1=="Delta"{print $2}')"

# ── archive results that cannot be taken at their word ──────────────────────
echo "an archive that happened but reported failure rolls forward"
reset; write_row fresh
out=$(run FAKE_ARCHIVE_LIES="$OLD" -- start); sleep 0.3
check "the old thread is archived" "archived" "$(active "$OLD")"
check "…and the new one is NOT discarded" "active" "$(active "$NEW")"
contains "…and is run" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
not_contains "…never the old one" "$(cat "$FIX/calls")" "resume $OLD"
check "…the replacement is finished" "" "$(txn_phase)"

echo "an archive whose result cannot be read stops, discarding nothing"
reset; write_row fresh
out=$(run FAKE_ARCHIVE_VANISH="$OLD" -- start); sleep 0.3
contains "it says it is stopping" "$out" "neither listed nor archived"
check "the new thread is not discarded" "active" "$(active "$NEW")"
not_contains "nothing is launched" "$(cat "$FIX/calls")" "resume "
check "the replacement is kept, marked uncertain" "archive-uncertain" "$(txn_phase)"
check "the row is kept on the old id" "$OLD" "$(jq -r '.[0].sid' "$STATE")"
# Once the old thread is found archived, the same transaction rolls forward.
mkdir -p "$CODEX_HOME/archived_sessions"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$OLD" "$FIX/work" \
  > "$CODEX_HOME/archived_sessions/rollout-2026-01-01T00-00-00-$OLD.jsonl"
out=$(run -- start); sleep 0.3
check "the re-run makes no second thread" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
contains "…and runs the new thread" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
check "…and finishes" "" "$(txn_phase)"

# ── the journal outlives a row it could not settle ─────────────────────────
echo "a verified launch whose row cannot be settled keeps the journal"
reset; write_row fresh
crash_start FAKE_TMUX_CRASH=after
: > "$STATE.acklock"
out=$(run -- start); sleep 0.3
rm -f "$STATE.acklock"
contains "it says the replacement stays pending" "$out" "could not settle its restart row"
check "the journal is kept" "rewritten" "$(txn_phase)"
check "the row is still pending" "fresh" "$(jq -r '.[0].mode' "$STATE")"
out=$(run -- start); sleep 0.3
contains "the next start settles it" "$out" "Gamma is running on its new Codex thread $NEW"
check "…journal gone" "" "$(txn_phase)"

# ── the claim excludes ──────────────────────────────────────────────────────
echo "something that is not a claim at the claim path fails closed"
reset; write_row fresh
mkdir -p "$STATEDIR/codex-fresh/$key.json.lock"
out=$(run -- start); sleep 0.3
rmdir "$STATEDIR/codex-fresh/$key.json.lock"
contains "it refuses, saying why" "$out" "is not a claim"
check "no thread is made" "0" "$(line_of 'app-server')"
check "the old thread is untouched" "active" "$(active "$OLD")"

# ── a foreign process is not codex ──────────────────────────────────────────
impostor_pane() { # <stamp?> [command]: a pane named like the session, running something codex-looking
  rtmux new-session -d -s codex_Gamma -c "$FIX" "${2:-python3 -c 'import time; time.sleep(60)' 'codex helper resume $NEW'}"
  if [ "$1" = "stamp" ]; then
    rtmux set-option -t "=codex_Gamma:" @cl_agent codex; rtmux set-option -t "=codex_Gamma:" @cl_sid "$NEW"
  fi
  sleep 0.3
}
echo "a stamped pane running a codex-looking python is not taken for codex"
reset; write_row fresh
crash_start FAKE_TMUX_CRASH=before
check "fixture: the replacement is pending" "rewritten" "$(txn_phase)"
impostor_pane stamp
out=$(run -- start); sleep 0.3
not_contains "it is not settled" "$out" "is running on its new Codex thread"
check "…the journal stays" "rewritten" "$(txn_phase)"
# Two more shapes, one per rule: an executable that is not codex, and a codex
# whose first word is a subcommand other than resume.
mkdir -p "$FIX/nm/@openai/codex/bin" "$FIX/nbin"
printf 'setTimeout(function(){}, 59000);\n' > "$FIX/nm/@openai/codex/bin/codex.js"
printf 'setTimeout(function(){}, 59000);\n' > "$FIX/nm/hold.js"
# Codex's two-directory case: a node started in a FOREIGN directory on its own
# ./entry (not the launcher), while cl's own working directory — where the
# check runs — has an ./entry that IS a symlink to the launcher. Resolved in
# the checker's directory, the foreign process would pass.
mkdir -p "$FIX/foreign"
printf 'setTimeout(function(){}, 59000);\n' > "$FIX/foreign/entry"
ln -sf "$FIX/nm/@openai/codex/bin/codex.js" "$FIX/entry"
# The node impostors (the review's `node -e … -- <codex.js> resume <id>`, and
# -p, --require x <codex.js>) put a real codex.js in argv, but not as the
# entry script: node runs other code. Only `node <codex.js> …` is Codex.
# The review's shape (one argv[0] of "codex resume <id>" on /bin/sleep), an
# executable that is not codex, and a genuine codex executable whose first
# word is a subcommand other than resume.
for imp in "exec -a 'codex resume $NEW' /bin/sleep 60" "exec -a 'helper resume $NEW' sleep 60" \
           "exec -a codex '$FIX/stub/codex' helper resume $NEW" \
           "exec python3 -c 'import time; time.sleep(60)' resume $NEW" \
           "exec node -e 'setTimeout(function(){},59000)' resume $NEW" \
           "exec node -e 'setTimeout(()=>{},59000)' -- '$FIX/nm/@openai/codex/bin/codex.js' resume $NEW" \
           "exec node -p 'setTimeout(()=>{},59000)' '$FIX/nm/@openai/codex/bin/codex.js' resume $NEW" \
           "exec node --require '$FIX/nm/hold.js' '$FIX/nm/@openai/codex/bin/codex.js' resume $NEW" \
           "exec node '$FIX/nm/hold.js' resume $NEW" \
           "cd '$FIX/foreign' && exec node ./entry resume $NEW"; do
  case "$imp" in *node*) command -v node >/dev/null 2>&1 || continue ;; esac
  rtmux kill-server >/dev/null 2>&1
  impostor_pane stamp "$imp"
  out=$(run -- start); sleep 0.3
  not_contains "[$imp] is not taken for codex" "$out" "is running on its new Codex thread"
  check "[$imp] …the journal stays" "rewritten" "$(txn_phase)"
done
echo "the real launch forms are taken for codex: the binary, and node running its launcher"
for form in direct node-script node-symlink; do
  if [ "$form" != direct ] && ! command -v node >/dev/null 2>&1; then echo "  (skipped $form: no node)"; continue; fi
  rtmux kill-server >/dev/null 2>&1
  mkdir -p "$FIX/nm/@openai/codex/bin" "$FIX/nbin"
  printf 'setTimeout(function(){}, 59000);\n' > "$FIX/nm/@openai/codex/bin/codex.js"
  ln -sf "$FIX/nm/@openai/codex/bin/codex.js" "$FIX/nbin/codex"
  case "$form" in
    direct)       cmd="exec -a codex '$FIX/stub/codex' --some-flag resume $NEW" ;;
    node-script)  cmd="exec node '$FIX/nm/@openai/codex/bin/codex.js' resume $NEW" ;;
    node-symlink) cmd="exec node '$FIX/nbin/codex' -m some-model resume $NEW" ;;
  esac
  impostor_pane stamp "$cmd"
  out=$(run -- start); sleep 0.3
  contains "[$form] is taken for codex and settled" "$out" "is running on its new Codex thread $NEW"
  # Put the replacement back to pending for the next form.
  _key=$(printf 'codex\037%s' Gamma | shasum -a 256 | cut -c1-40)
  jq -n --arg o "$OLD" --arg n "$NEW" '{agent:"codex",name:"Gamma",old_sid:$o,new_sid:$n,cycle:"c",phase:"rewritten"}' > "$STATEDIR/codex-fresh/$_key.json"
  jq -n --arg n "$NEW" --arg o "$OLD" --arg c "$FIX/work" '[{name:"Gamma",sid:$n,cwd:$c,agent:"codex",mode:"fresh",fresh_from:$o,fresh_pending:"c"}]' > "$STATE"
done
rtmux kill-server >/dev/null 2>&1
# The journal is pending again after the loop; the cases below expect it so.
echo "an identity that cannot be read is no evidence"
lib="$FIX/cl-lib.sh"
sed '/^# Optional agent filter for direct launch/,$d' "$CL" > "$lib"
( exec -a codex "$FIX/stub/codex" resume "$NEW" ) & idp=$!; echo "$idp" >> "$FIX/procs"; sleep 0.3
check "control: the stand-in is accepted with python3 present" "0" \
  "$(env -i HOME="$HOME" PATH="/usr/bin:/bin" bash -c ". '$lib'; _codex_argv_resumes $idp $NEW; echo \$?")"
mkdir -p "$FIX/nopy"; for c in basename realpath; do ln -sf "$(command -v $c)" "$FIX/nopy/$c"; done
check "no python3 on PATH: no evidence" "1" \
  "$(env -i HOME="$HOME" PATH="$FIX/nopy" /bin/bash -c ". '$lib'; _codex_argv_resumes $idp $NEW; echo \$?")"
mkdir -p "$FIX/badpy"; printf '#!/bin/sh\nexit 1\n' > "$FIX/badpy/python3"; chmod +x "$FIX/badpy/python3"
check "a python3 that fails: no evidence" "1" \
  "$(env -i HOME="$HOME" PATH="$FIX/badpy:/usr/bin:/bin" bash -c ". '$lib'; _codex_argv_resumes $idp $NEW; echo \$?")"
# Each element through %s, so an id starting with digits is not read as an
# octal escape after the NUL.
printf '#!/bin/sh\nprintf "%%s\\0" /x/codex codex resume %s\nexit 1\n' "$NEW" > "$FIX/badpy/python3"
check "a read that prints a whole answer and then fails: no evidence" "1" \
  "$(env -i HOME="$HOME" PATH="$FIX/badpy:/usr/bin:/bin" bash -c ". '$lib'; _codex_argv_resumes $idp $NEW; echo \$?")"
kill "$idp" 2>/dev/null; wait "$idp" 2>/dev/null
check "a pid that is gone: no evidence" "1" \
  "$(env -i HOME="$HOME" PATH="/usr/bin:/bin" bash -c ". '$lib'; _codex_argv_resumes $idp $NEW; echo \$?")"
check "not a pid at all: no evidence" "1" \
  "$(env -i HOME="$HOME" PATH="/usr/bin:/bin" bash -c ". '$lib'; _codex_argv_resumes 'x;y' $NEW; echo \$?")"
echo "…nor adopted when unstamped"
rtmux kill-server >/dev/null 2>&1
impostor_pane nostamp
out=$(run -- start); sleep 0.3
not_contains "it is not adopted" "$out" "adopting"
check "…and stays unstamped" "" "$(rtmux show-option -qv -t "=codex_Gamma:" @cl_agent 2>/dev/null)"
check "…the journal stays" "rewritten" "$(txn_phase)"
rtmux kill-server >/dev/null 2>&1

# ── the window before the new id is written down ────────────────────────────
echo "a crash after thread/start took effect, before the id was saved: it stops, adopting nothing"
reset; write_row fresh
crash_start FAKE_CRASH_AT=start-created
check "fixture: it crashed with the id unsaved" "begun" "$(txn_phase)"
check "fixture: …and the thread exists, carrying the marker" "active" "$(active "$NEW")"
out=$(run -- start); sleep 0.3
contains "the retry stops, naming the thread" "$out" "may have made thread(s) $NEW"
not_contains "…adopting nothing" "$out" "recovered"
check "…making no second thread" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
not_contains "…launching nothing" "$(cat "$FIX/calls")" "resume "
check "…archiving nothing" "active" "$(active "$OLD")"
check "…and keeping the journal for the person to settle" "begun" "$(txn_phase)"
recovery=$(printf '%s\n' "$out" | sed -n 's/^    \(rm .*\)$/\1/p' | head -1)
contains "it prints how to clear this replacement" "$recovery" "rm "
eval "$recovery"
check "…which removes exactly this journal" "" "$(txn_phase)"

echo "…and two threads carrying the marker are ambiguous: it stops"
reset; write_row fresh
crash_start FAKE_CRASH_AT=start-created
STRAY=01dddddd-0000-7000-8000-$RUN_TAG
marker=$(jq -r '.marker' "$STATEDIR"/codex-fresh/*.json)
jq -cn --arg i "$STRAY" --arg c "$FIX/work" --arg m "$marker" '{type:"session_meta",payload:{id:$i,cwd:$c,thread_source:$m}}' \
  > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$STRAY.jsonl"
out=$(run -- start); sleep 0.3
contains "it stops, naming both" "$out" "may have made thread(s)"
check "no second thread is made" "1" "$(grep -c 'app-server thread/start' "$FIX/calls")"
check "nothing is archived" "active" "$(active "$OLD")"
not_contains "nothing is launched" "$(cat "$FIX/calls")" "resume "
check "the journal stays at begun" "begun" "$(txn_phase)"

echo "an unrelated unnamed thread in the same repo is never adopted (the review's case)"
reset; write_row fresh
crash_start FAKE_CRASH_AT=start-early
UNREL=01ffffff-0000-7000-8000-$RUN_TAG
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","timestamp":"2020-01-01T00:00:00Z"}}\n' "$UNREL" "$FIX/work" \
  > "$CODEX_HOME/sessions/2026/01/01/rollout-2020-01-01T00-00-00-$UNREL.jsonl"
touch "$CODEX_HOME/sessions/2026/01/01/rollout-2020-01-01T00-00-00-$UNREL.jsonl"
out=$(run -- start); sleep 0.3
not_contains "it is not taken for this replacement's" "$out" "may have made thread"
not_contains "it is never renamed or resumed" "$(cat "$FIX/calls")" "$UNREL"
check "…and stays listed, untouched" "active" "$(active "$UNREL")"
contains "the replacement makes its own thread instead" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
echo "…and a thread with a different marker is not adopted either"
reset; write_row fresh
crash_start FAKE_CRASH_AT=start-early
jq -cn --arg i "$UNREL" --arg c "$FIX/work" '{type:"session_meta",payload:{id:$i,cwd:$c,thread_source:"cl-fresh:someone-else"}}' \
  > "$CODEX_HOME/sessions/2026/01/01/rollout-2020-01-01T00-00-00-$UNREL.jsonl"
out=$(run -- start); sleep 0.3
not_contains "it is not taken for this one's" "$out" "may have made thread"
check "…and stays listed" "active" "$(active "$UNREL")"

echo "a crash before anything persisted: the retry simply makes the thread"
reset; write_row fresh
crash_start FAKE_CRASH_AT=start-early
out=$(run -- start); sleep 0.3
check "two thread/starts, one thread" "2" "$(grep -c 'app-server thread/start' "$FIX/calls")"
contains "the new thread is run" "$(cat "$FIX/calls")" "resume $NEW | cl started you"
check "finished" "" "$(txn_phase)"

# ── coordination is reported pending, never done ────────────────────────────
echo "with a coordination helper installed, the lane is reported unverified"
reset; write_row fresh
out=$(run -- start); sleep 0.3
contains "it says coordination is not verified" "$out" 'coordination for "Gamma" is NOT verified'
echo "…and without one, nothing is said"
reset; write_row fresh
out=$(run CL_COORD_REARM="$FIX/not-installed.sh" -- start); sleep 0.3
not_contains "no coordination line" "$out" "coordination for"

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
