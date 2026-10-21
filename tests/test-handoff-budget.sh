#!/usr/bin/env bash
# Parallel-handoff + budget tests — run: tests/test-handoff-budget.sh
#
# ── WHAT WENT WRONG, TWICE ──────────────────────────────────────────────────
#
# A real `cl stop` over nineteen sessions produced two handoffs and nineteen
# losses. The log:
#
#   ⏳ asked "Alpha" ... (attempt 1 of 3) — waiting up to 90s
#   ⚠ no handoff from "Alpha" after 90s
#   ⏳ asked "Alpha" ... (attempt 2 of 3) — waiting up to 90s
#   ⚠ no handoff from "Alpha" after 90s
#   ⏳ asked "Alpha" ... (attempt 3 of 3) — waiting up to 90s
#   ✓ handoff written for "Alpha"
#   ⏳ asked "<next>" ... — waiting up to 54s          <- 246s already gone
#   ... then eighteen × "the 300s handoff budget for this stop is spent"
#
# The first round of fixes addressed the two visible defects — a BUSY claude
# queues typed input so a retry only stacks copies (handoff_target_busy), and
# attempts × timeout could eat 90% of the whole budget (a per-session cap). Both
# were real. Neither touched the shape underneath:
#
#   the wait was SERIAL, so a stop cost `sessions × share` in wall clock
#   while each session's share was `budget / sessions`.
#
# Both numbers move the wrong way as sessions accumulate, so the fair-share
# machinery was rationing a resource that did not need rationing. On the second
# nineteen-session stop (2026-10-12) twelve sessions were again stopped with no
# handoff, because 300/19 = 15s floored to 45s exhausts the budget after six.
#
# So the asks now go out TOGETHER and one window covers all of them. The
# properties under test are therefore:
#
#   * every eligible session is asked BEFORE any of them is waited for;
#   * the wait is one shared window, not one per session;
#   * each session gets the WHOLE window — no division, no floor, no ordering
#     dependence (so the suite's old fair-share cases are gone, not ported:
#     there is no divisor left to be unfair);
#   * the budget still bounds the whole phase;
#   * a session that is merely still WORKING is not re-asked;
#   * nothing is killed until the wait is over.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-budget.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "wanted [$3] in: $2" ;; esac; }
not_contains() { case "$2" in *"$3"*) bad "$1" "did NOT want [$3] in: $2" ;; *) ok "$1" ;; esac; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }

# The REAL functions, verbatim — a reimplementation here would only prove the
# reimplementation works. The shape-tracking awk matters: a one-liner definition
# breaks a naive sed range.
extract_fns() {
  local f="$1"; shift
  local n
  for n in "$@"; do
    awk -v n="$n" '
      !inf && $0 ~ "^"n"\\(\\)" {
        print
        if ($0 ~ /}[[:space:]]*$/) next
        inf = 1; next
      }
      inf { print; if ($0 ~ /^}$/) inf = 0 }
    ' "$f"
  done
}

LIB="$FIX/lib.sh"
extract_fns "$CL" handoff_target_busy handoff_nonce run_bounded send_text_tmux handoff_send_once request_handoff > "$LIB"
for fn in handoff_target_busy handoff_nonce run_bounded send_text_tmux handoff_send_once request_handoff; do
  grep -q "^${fn}()" "$LIB" || setup_failed "could not extract ${fn} from the shipped script"
done
# Guards on the extract, not on the product: if these functions ever stop
# consulting the busy check or routing sends through the one dispatcher, these
# tests must fail loudly rather than keep passing against something else.
grep -q 'handoff_target_busy' "$LIB" || setup_failed "extracted request_handoff never consults the busy check"
grep -q 'handoff_send_once'   "$LIB" || setup_failed "extracted request_handoff does not send via handoff_send_once"

echo "handoff_target_busy asks about the PROCESS, not the terminal"
tb() { # <tmux-has-session-rc> <session_busy-rc> <pid> <claude_busy-rc>
  (
    . "$LIB"
    eval "tmux() { case \"\$1\" in has-session) return $1 ;; esac; return 1; }"
    eval "session_busy() { return $2 ; }"
    eval "session_pid() { printf '%s' '$3' ; }"
    eval "claude_busy() { return $4 ; }"
    if handoff_target_busy "tname" "sid" "name"; then echo busy; else echo idle; fi
  )
}
check "a live tmux pane mid-task is busy"              "busy" "$(tb 0 0 '' 1)"
check "…and an idle one is not"                        "idle" "$(tb 0 1 '' 1)"
# The iTerm case: no tmux session, so the recorded pid is the only handle.
check "no tmux but a recorded pid mid-task is busy"    "busy" "$(tb 1 1 4242 0)"
check "…and no pid at all is not busy, not an error"   "idle" "$(tb 1 1 '' 0)"

echo "handoff_send_once picks ONE route and does not spray the prompt around"
sd() { # <tmux-has-session-rc> <tmux-send-rc> <iterm-rc>
  (
    . "$LIB"
    HOME="$FIX/sendhome"
    eval "tmux() { case \"\$1\" in has-session) return $1 ;; esac; return 1; }"
    eval "send_text_tmux() { echo tmux >> '$FIX/route.log'; return $2 ; }"
    eval "send_text_iterm() { echo iterm >> '$FIX/route.log'; return $3 ; }"
    handoff_send_once "N" "sid" "tname" "PROMPT" && echo sent || echo unreachable
  )
}
: > "$FIX/route.log"; check "a live tmux pane takes the tmux route" "sent" "$(sd 0 0 1)"
check "…and only that route"  "tmux" "$(sort -u "$FIX/route.log" | tr -d '\n')"
# THE DELIBERATE NON-FALLTHROUGH. A live tmux session that refuses send-keys is
# a broken pane, not an iTerm tab — typing a handoff request into some other
# window is worse than reporting it unreachable.
: > "$FIX/route.log"; check "a tmux pane that refuses the send is unreachable" "unreachable" "$(sd 0 1 0)"
not_contains "…and the prompt is NOT then typed into iTerm" "$(cat "$FIX/route.log")" "iterm"
: > "$FIX/route.log"; check "no tmux session falls through to iTerm" "sent" "$(sd 1 1 0)"
: > "$FIX/route.log"; check "…and with neither, it reports unreachable" "unreachable" "$(sd 1 1 1)"

echo "the probe's signal handling terminates rather than resuming"
# ── WHY A TRAP THAT RETURNS IS NOT A TRAP ───────────────────────────────────
#
# tools/iterm-broadcast-probe.sh had `trap cleanup EXIT INT TERM`. A handler
# that RETURNS does not terminate the script: bash resumes where it was
# interrupted. So Ctrl-C closed the probe's tabs and deleted its working
# directory, then the probe carried on polling for capture files that no longer
# existed and ran cleanup a second time at exit.
#
# Worst possible script for it: a GUI probe, where Ctrl-C is exactly what an
# operator reaches for when the tabs look wrong. (Codex, PR #19 review.)
PROBE="$HERE/../tools/iterm-broadcast-probe.sh"
[ -r "$PROBE" ] || setup_failed "the probe is missing"
# ANCHORED TO REAL TRAP LINES, not to any occurrence of the text: the probe's
# own comment quotes the old form verbatim to explain what was wrong with it, so
# a plain substring search finds the documentation and condemns the fix.
check "no live trap shares one handler across EXIT INT TERM" "0" \
  "$(grep -c '^trap cleanup EXIT INT TERM' "$PROBE")"
check "…EXIT owns the cleanup"       "1" "$(grep -c '^trap cleanup EXIT$' "$PROBE")"
check "…and INT exits through it"    "1" "$(grep -c "^trap 'exit 130' INT\$" "$PROBE")"
check "…as does TERM"                "1" "$(grep -c "^trap 'exit 143' TERM\$" "$PROBE")"

# And the BEHAVIOUR, on a reduced fixture carrying only that structure — no
# iTerm tab is opened, so this runs anywhere.
TRAPFIX="$FIX/traps.sh"
cat > "$TRAPFIX" <<'TRAPEOF'
#!/usr/bin/env bash
set -u
LOG="$1"
_CLEANED=0
cleanup() { [ "$_CLEANED" = "1" ] && return 0; _CLEANED=1; echo "cleanup" >> "$LOG"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
i=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
echo "RESUMED" >> "$LOG"
TRAPEOF
# The control: the OLD form, which must FAIL these same assertions. Without it
# this section would pass against any script that happens to exit.
sed "s/trap 'exit 130' INT/trap cleanup INT/; s/trap 'exit 143' TERM/trap cleanup TERM/" \
  "$TRAPFIX" > "$FIX/traps-old.sh"
run_trap() { # <script> <signal> -> "<status> <cleanups> <resumed>"
  local lg="$FIX/trap.log"; : > "$lg"
  bash "$1" "$lg" & local tp=$!
  sleep 1; kill -"$2" "$tp" 2>/dev/null; wait "$tp" 2>/dev/null; local rc=$?
  printf '%s %s %s' "$rc" "$(grep -c '^cleanup$' "$lg")" "$(grep -c RESUMED "$lg")"
}
# TERM rather than INT: bash sets SIGINT to IGNORED for a background job in a
# non-interactive shell, so a harness cannot deliver it this way — measured, the
# INT case reaches the end of the script untouched. TERM exercises the identical
# code path, and the structural assertions above cover INT's spelling.
check "TERM terminates with its own status, cleaning up once" "143 1 0" "$(run_trap "$TRAPFIX" TERM)"
check "…where the old form resumed instead (status 0, work done after cleanup)" \
  "0 1 1" "$(run_trap "$FIX/traps-old.sh" TERM)"

echo "run_bounded puts a ceiling on a send that would otherwise hang a stop"
# ── WHY EVERY SEND IS BOUNDED ───────────────────────────────────────────────
#
# Codex's PR #19 review: "an unbounded backend call can still hold the stop
# before the budget starts." Every route here talks to something that can wedge
# — osascript waits on iTerm which waits on a GUI, and tmux on its server —
# and macOS ships no coreutils `timeout`.
rb() { ( . "$LIB"; run_bounded "$@" >/dev/null 2>&1; echo $? ); }
check "a command inside the limit returns its own status"  "0"   "$(rb 2 true)"
check "…including a non-zero one"                          "3"   "$(rb 2 sh -c 'exit 3')"
start=$(date +%s)
check "a command that overruns is killed and reports 124"  "124" "$(rb 1 sleep 30)"
elapsed=$(( $(date +%s) - start ))
check "…promptly, rather than waiting the full 30s"        "1"   "$([ "$elapsed" -lt 8 ] && echo 1 || echo 0)"

echo "…and the BACKEND is what dies, not just the wrapper around it"
# ── THE TEST THAT WAS HIDING THE BUG ────────────────────────────────────────
#
# The first version of this stubbed `send_text_tmux() { exec sleep 30; }`.
# `exec` replaces the subshell with sleep, so `$!` WAS the sleep and killing it
# worked — proving a topology production never has. Every real backend is a
# shell FUNCTION, so backgrounding it makes `$!` a subshell and the actual
# tmux/osascript is its CHILD; killing `$!` alone left the backend running while
# the code printed "killed it". (Codex, PR #19 review, which reproduced it.)
#
# So this uses the REAL send_text_tmux with a fake `tmux` that records its own
# pid and then sleeps — the production shape — and asserts that pid is gone.
bk() { # <seconds-limit> -> "<verdict> <backend-alive>"
  local bin="$FIX/bk"; rm -rf "$bin"; mkdir -p "$bin"
  # A fake tmux: has-session succeeds, send-keys records its pid and hangs.
  cat > "$bin/tmux" <<'TMUXEOF'
#!/bin/sh
case "$1" in
  has-session) exit 0 ;;
  send-keys)   echo $$ > "$BK_PIDFILE"; exec sleep 60 ;;
esac
exit 1
TMUXEOF
  chmod +x "$bin/tmux"
  : > "$FIX/bk.pid"
  (
    . "$LIB"
    PATH="$bin:$PATH"
    BK_PIDFILE="$FIX/bk.pid"; export BK_PIDFILE
    CL_HANDOFF_SEND_TIMEOUT="$1"
    # THE REAL send_text_tmux, extracted, not a stub of it.
    handoff_send_once "Wedged" "sid" "tname" "PROMPT" >/dev/null 2>&1 && echo -n sent || echo -n unreachable
  )
  printf ' '
  local bp; bp="$(cat "$FIX/bk.pid" 2>/dev/null)"
  if [ -n "$bp" ] && kill -0 "$bp" 2>/dev/null; then
    printf 'ALIVE'; kill -9 "$bp" 2>/dev/null
  else
    printf 'gone'
  fi
}
# Guard: the fake backend must actually have run, or "gone" is vacuous.
out="$(bk 1)"
check "the backend ran and was then killed with its wrapper" "unreachable gone" "$out"
check "…and its pid was really recorded (not a vacuous pass)" "1" \
  "$([ -s "$FIX/bk.pid" ] && echo 1 || echo 0)"

echo "…and handoff_send_once reports the route that wedged, instead of hanging"
hang() { # <seconds-limit>
  (
    . "$LIB"
    CL_HANDOFF_SEND_TIMEOUT="$1"
    eval "tmux() { case \"\$1\" in has-session) return 0 ;; esac; return 1; }"
    # `exec`, so the backgrounded process IS the sleep rather than a parent of
    # it — which is how the real backends behave (osascript/tmux are the
    # process run_bounded kills). A stub that forks leaves a grandchild holding
    # the captured stdout pipe, and the capture then blocks for the full 30s
    # even though the timeout fired correctly at 1s.
    send_text_tmux() { exec sleep 30; }
    handoff_send_once "Wedged" "sid" "tname" "PROMPT" && echo sent || echo unreachable
  ) 2>&1
}
start=$(date +%s)
out="$(hang 1)"
elapsed=$(( $(date +%s) - start ))
check "a hanging send does not hang the caller"  "1" "$([ "$elapsed" -lt 8 ] && echo 1 || echo 0)"
contains "…it says which backend was killed"     "$out" "tmux send"
contains "…and how long it waited"               "$out" "after 1s"
contains "…reporting the session unreachable"    "$out" "unreachable"

# ── request_handoff: still the SINGLE-session path (`cl start --fresh`) ──────
# `cl stop` no longer uses it; it remains the right shape for one session, where
# serial IS the whole job. Driven with stubs, because a real busy claude cannot
# be fixtured. SENDS ARE COUNTED IN A FILE: the function runs in a subshell, so
# a counter variable would be lost — the same out-param-through-a-subshell trap
# this project has hit before.
SENDS="$FIX/sends.log"
run_rh() { # <busy-rc> <attempts> <timeout> <session-cap>
  : > "$SENDS"
  (
    . "$LIB"
    CL_HANDOFF_ATTEMPTS="$2" CL_HANDOFF_TIMEOUT="$3"
    _CL_BUDGET_LEFT=-1 _CL_SESSION_CAP="$4"
    eval "handoff_target_busy() { return $1 ; }"
    handoff_root() { _CL_HANDOFF_ROOT="$FIX/root"; return 0; }
    handoff_path() { printf '%s/never-written.md' "$FIX"; }
    handoff_is_manual() { return 1; }
    # Never matches, so every attempt runs to its full window — the window is
    # what is being measured.
    handoff_marker() { printf ''; }
    build_handoff_prompt() { printf 'ASK nonce=%s' "$3"; }
    handoff_send_once() { printf '%s\n' "$4" >> "$SENDS"; return 0; }
    request_handoff "Target" "sid-1" "$FIX" "tname" ""
  ) > "$FIX/rh.out" 2>&1
  echo $?
}
sends()  { grep -c . "$SENDS" 2>/dev/null || echo 0; }
nonces() { sed -n 's/.*nonce=//p' "$SENDS" | sort -u | grep -c . || echo 0; }

echo "one session that is still WORKING is waited for, not asked again"
rc=$(run_rh 0 3 1 -1)
# THE REGRESSION. Three attempts used to mean three typed copies stacked in one
# input box; the first ask was never lost, only queued.
check "it is asked exactly ONCE across three attempts" "1" "$(sends)"
contains "…and says the request is queued, not lost" "$(cat "$FIX/rh.out")" "QUEUED, not lost"
# Reusing the nonce is REQUIRED on this path: the nonce it is waiting for must
# stay the one it actually sent, or a real answer could never be recognised.
check "…still waiting on the nonce it did send" "1" "$(nonces)"
check "…and reports no handoff rather than claiming success" "2" "$rc"

echo "…while an IDLE session with nothing landing is genuinely re-asked"
# The complement. If busy-awareness suppressed every retry, a genuinely lost
# ask would never be re-sent and the fix would have broken the feature.
rc=$(run_rh 1 3 1 -1)
check "three attempts mean three asks" "3" "$(sends)"
check "…each with a fresh nonce, so a late answer to #1 cannot confirm #3" "3" "$(nonces)"
check "…and the send path really ran (not a vacuous pass)" "1" "$([ "$(sends)" -gt 0 ] && echo 1 || echo 0)"

echo "…and a caller that imposes a cap still has it honoured"
# Nothing sets these any more, but they are request_handoff's contract with any
# future caller that needs a ceiling, and -1 was itself a bug once.
start=$(date +%s)
rc=$(run_rh 1 3 2 1)   # cap 1s, but 3 attempts × 2s = 6s if uncapped
elapsed=$(( $(date +%s) - start ))
check "it stops at the cap instead of taking every attempt" "1" "$([ "$elapsed" -lt 5 ] && echo 1 || echo 0)"
contains "…and says whose share ran out" "$(cat "$FIX/rh.out")" "used its 1s share"
check "…returning 'no handoff' so the caller resumes as-is" "2" "$rc"
start=$(date +%s)
run_rh 1 2 2 -1 >/dev/null
check "an uncapped caller still uses its full attempts" "1" \
  "$([ $(( $(date +%s) - start )) -ge 3 ] && echo 1 || echo 0)"

# ── the behavioural core: a real `cl stop` over several live sessions ────────
export HOME="$FIX/home"
BASEPATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$HOME/.claude/projects/p1" "$HOME/.config/claude-session" || setup_failed "fixture HOME"
command -v tmux >/dev/null 2>&1 || setup_failed "tmux is needed to observe a real broadcast"
TMUX_TMPDIR="$FIX/tmux-tmp"; mkdir -p "$TMUX_TMPDIR"
rtmux() { TMUX_TMPDIR="$TMUX_TMPDIR" tmux "$@"; }
trap 'rtmux kill-server >/dev/null 2>&1; rm -rf "$FIX"' EXIT

# ── A SIMULATED AGENT ───────────────────────────────────────────────────────
#
# The suite could not previously watch a handoff LAND: the completion token is a
# fresh nonce generated inside the run, so no fixture can predict it, and every
# earlier test therefore drove a session that answered nothing. That is exactly
# how a serial wait looked identical to a parallel one.
#
# This reads the prompt off its own stdin — the way the real agent receives it —
# pulls the path and the nonce OUT of that text, and writes the file the way the
# prompt demands: temp file, terminal marker, atomic rename. Nothing is passed
# to it out of band, so it also proves the prompt carries everything an agent
# needs.
AGENT="$FIX/agent.py"
cat > "$AGENT" <<'PYEOF'
import os, re, sys, termios, time
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
data = b""
try:
    new = termios.tcgetattr(fd)
    new[3] = new[3] & ~termios.ECHO & ~termios.ICANON
    termios.tcsetattr(fd, termios.TCSADRAIN, new)
    while True:
        c = sys.stdin.buffer.read(1)
        if not c or c in (b"\r", b"\n"):
            break
        data += c
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
text = data.decode("utf-8", "replace")
with open(os.environ["AGENT_RECV"], "w") as fh:
    fh.write(text)
path = re.search(r'handoff to "([^"]+)"', text)
nonce = re.search(r'(clho:[0-9]+:[0-9]+:[0-9]+:[0-9]+)', text)
# Deliberately AFTER the read: a handoff is work, and a window that only passes
# against an instant answer is not testing a window.
time.sleep(float(os.environ.get("AGENT_DELAY", "1")))
mode = os.environ.get("AGENT_ANSWER", "1")
if path and mode != "0":
    hp = path.group(1)
    os.makedirs(os.path.dirname(hp), exist_ok=True)
    if mode == "1" and nonce:
        body = "simulated handoff\n\n<!-- cl:%s -->\n" % nonce.group(1)
    elif mode == "partial":
        # Cut off mid-write: real content, no terminal marker. The whole reason
        # the marker is the signal rather than the file's existence.
        body = "simulated handoff that was cut off mid-sent"
    elif mode == "quoted" and nonce:
        # The nastiest shape, and the reason the check is on the LAST line
        # rather than on the token being present: an agent that explains what
        # it is about to do, quotes the token, and is then cut off. The file
        # contains this very request's nonce and is still incomplete.
        body = ("I will finish by writing <!-- cl:%s --> as the last line.\n"
                "Current state: halfway through describing the wo"
                % nonce.group(1))
    else:
        # A leftover from an earlier rotation: complete, but answering a
        # question nobody asked this time.
        body = "stale handoff\n\n<!-- cl:clho:1:1:1:1 -->\n"
    tmp = hp + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(body)
    os.rename(tmp, hp)
time.sleep(120)
PYEOF

mk_agent() { # <name> <mtime> <delay> <answer 0|1>
  printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX" "$1" \
    > "$HOME/.claude/projects/p1/sid-$1.jsonl"
  touch -t "$2" "$HOME/.claude/projects/p1/sid-$1.jsonl"
  rtmux new-session -d -s "$1" -c "$FIX" \
    "AGENT_RECV='$FIX/recv-$1.txt' AGENT_DELAY='$3' AGENT_ANSWER='$4' python3 '$AGENT'" 2>/dev/null
}
reset_sessions() { rm -f "$HOME/.claude/projects/p1/"*.jsonl "$FIX"/recv-*.txt; }

echo "every eligible session is asked BEFORE any of them is waited for"
# THE SHAPE ITSELF. Serially, session 2 was not asked until session 1 had been
# waited out — which is why twelve of nineteen were never asked at all. Order in
# the transcript is the observable: all three asks, then the wait.
reset_sessions
mk_agent AgentA 202610121200 1 1
mk_agent AgentB 202610121100 1 1
mk_agent AgentC 202610121000 1 1
start=$(date +%s)
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-par" CL_HANDOFF_TIMEOUT=25 CL_HANDOFF_ATTEMPTS=1 \
  bash "$CL" stop --keep-tabs > "$FIX/par.out" 2>&1
par_elapsed=$(( $(date +%s) - start ))
par="$(cat "$FIX/par.out")"
# A premise guard first: without three real asks every ordering claim below
# would pass by describing an empty run.
check "all three were asked" "3" "$(grep -c '→ asked' "$FIX/par.out")"
last_ask=$(grep -n '→ asked'       "$FIX/par.out" | tail -1 | cut -d: -f1)
first_wait=$(grep -n 'waiting up to' "$FIX/par.out" | head -1 | cut -d: -f1)
check "…and the LAST ask precedes the FIRST wait" "1" \
  "$([ -n "$last_ask" ] && [ -n "$first_wait" ] && [ "$last_ask" -lt "$first_wait" ] && echo 1 || echo 0)"

echo "…they then write concurrently, and the window is shared"
check "all three handoffs landed"  "3" "$(grep -c 'handoff written for' "$FIX/par.out")"
contains "…counted off as they arrive"  "$par" "(3 of 3"
contains "…and totalled at the end"     "$par" "3 of 3 asked handoff(s) landed."
# THE WHOLE POINT, IN SECONDS. Three agents each sleeping 1s land together in
# about a second; serially this was three separate waits. The early exit makes
# it faster still — the loop stops the moment nothing is pending.
check "three sessions cost about ONE window, not three" "1" \
  "$([ "$par_elapsed" -lt 20 ] && echo 1 || echo 0)"
# And the files are real, not just announced.
check "the handoff files exist on disk" "3" \
  "$(ls -1 "$FIX/store-par"/Agent*.md 2>/dev/null | wc -l | tr -d ' ')"
contains "…with a terminal marker, written by the agent" \
  "$(tail -1 "$FIX/store-par/AgentA.md" 2>/dev/null)" "<!-- cl:clho:"
# The prompt alone had to carry the path and the token, since nothing was passed
# to the agent out of band.
contains "the prompt that reached the pane named the file" \
  "$(cat "$FIX/recv-AgentA.txt" 2>/dev/null)" "handoff to"
rtmux kill-server >/dev/null 2>&1

echo "every session gets the WHOLE window — the budget is no longer divided"
# The old arithmetic: budget/sessions, floored. Nineteen sessions got 45s each
# and the seventh onward got nothing. There is no divisor now, so the announced
# window is the full timeout however many sessions there are.
reset_sessions
mk_agent NoAnsA 202610121200 1 0
mk_agent NoAnsB 202610121100 1 0
mk_agent NoAnsC 202610121000 1 0
start=$(date +%s)
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-none" CL_HANDOFF_TIMEOUT=4 CL_HANDOFF_ATTEMPTS=1 \
  bash "$CL" stop --keep-tabs > "$FIX/none.out" 2>&1
none_elapsed=$(( $(date +%s) - start ))
none="$(cat "$FIX/none.out")"
check "three sessions were asked"  "3" "$(grep -c '→ asked' "$FIX/none.out")"
contains "the announced window is the full timeout, not a third of it" "$none" "waiting up to 4s for 3 handoff(s)"
check "…and there is exactly ONE wait for all of them" "1" "$(grep -c 'waiting up to' "$FIX/none.out")"
# Serial would be 3 × 4s = 12s. Shared is ~4s.
check "…so the silence costs one window, not three"  "1" \
  "$([ "$none_elapsed" -lt 10 ] && echo 1 || echo 0)"
check "…and the run really did wait (not a vacuous fast pass)" "1" \
  "$([ "$none_elapsed" -ge 3 ] && echo 1 || echo 0)"
contains "each silent session is reported"     "$none" 'no handoff from "NoAnsA"'
contains "…and stopped anyway, resuming as-is" "$none" "stopping it anyway"
contains "…and the total says none landed"     "$none" "0 of 3 asked handoff(s) landed."
rtmux kill-server >/dev/null 2>&1

echo "a file is not a handoff — only THIS request's terminal marker is"
# ── FOUND BY THE REVERT MATRIX ──────────────────────────────────────────────
#
# Replacing the whole completion check with `[ -e "$path" ]` passed all 53
# assertions. The nonce comparison is the central correctness guard of the
# feature — it is what distinguishes a finished handoff from one cut off
# mid-write, and a fresh one from a leftover of an earlier rotation — and
# nothing in the stop path exercised it, because every fixture either answered
# properly or not at all.
#
# Both failure shapes are real and both were observed in review: a handoff
# truncated after the agent happened to mention the token, and a stale file
# still sitting in the store from a previous cycle.
reset_sessions
mk_agent PartialA 202610121200 1 partial
mk_agent StaleB   202610121100 1 stale
# A THIRD session that answers nothing at all, with a complete-but-old handoff
# already sitting in the store. It is the only one of the three whose file cl
# stop could be blamed for changing — StaleB's own agent rewrites its file, so
# asserting "left alone" there would measure the fixture, not the product.
mk_agent QuotedD    202610120900 1 quoted
mk_agent UntouchedC 202610121000 1 0
mkdir -p "$FIX/store-bad"
printf 'from last week\n\n<!-- cl:clho:2:2:2:2 -->\n' > "$FIX/store-bad/UntouchedC.md"
pre_stale="$(cat "$FIX/store-bad/UntouchedC.md")"
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-bad" CL_HANDOFF_TIMEOUT=6 CL_HANDOFF_ATTEMPTS=1 \
  bash "$CL" stop --keep-tabs > "$FIX/bad.out" 2>&1
badout="$(cat "$FIX/bad.out")"
check "all four were asked" "4" "$(grep -c '→ asked' "$FIX/bad.out")"
# The premise: both files DO exist, so `-e` alone would have counted them.
check "…and both wrote a file" "2" \
  "$(ls -1 "$FIX/store-bad/PartialA.md" "$FIX/store-bad/StaleB.md" 2>/dev/null | wc -l | tr -d ' ')"
contains "a file with no terminal marker is NOT a handoff" "$badout" 'no handoff from "PartialA"'
contains "…nor is one carrying an earlier rotation's marker" "$badout" 'no handoff from "StaleB"'
# THE TRUNCATION CASE. This file contains THIS request's nonce — a check for
# "is the token in the file?" accepts it — but the marker is not the last line,
# because the agent was cut off while still writing. That is precisely what the
# prompt's "write it last" instruction makes detectable.
contains "…nor one that quotes this run's token mid-prose and stops" "$badout" 'no handoff from "QuotedD"'
check "the quoted-token file really does contain the live nonce" "1" \
  "$(grep -c 'I will finish by writing' "$FIX/store-bad/QuotedD.md" 2>/dev/null | head -1)"
check "…so nothing landed"  "1" "$(printf '%s' "$badout" | grep -c '0 of 4 asked handoff(s) landed.')"
not_contains "…and neither is announced as written" "$badout" "handoff written for"
# The last known-good answer is left where it is: the agent's temp-then-rename
# replaces it only on success, so a failed ask must not destroy it.
check "a pre-existing handoff is left alone, not consumed" "$pre_stale" \
  "$(cat "$FIX/store-bad/UntouchedC.md" 2>/dev/null)"
rtmux kill-server >/dev/null 2>&1

echo "the budget still bounds the whole phase"
# It is wall clock for all rounds now rather than a pool to divide, so a budget
# under the window clamps the window.
reset_sessions
mk_agent BudgetA 202610121200 1 0
mk_agent BudgetB 202610121100 1 0
start=$(date +%s)
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-bud" CL_HANDOFF_TIMEOUT=60 CL_HANDOFF_ATTEMPTS=3 \
  CL_HANDOFF_BUDGET=3 bash "$CL" stop --keep-tabs > "$FIX/bud.out" 2>&1
bud_elapsed=$(( $(date +%s) - start ))
contains "a 3s budget clamps a 60s window" "$(cat "$FIX/bud.out")" "waiting up to 3s"
check "…and the stop really is that quick" "1" \
  "$([ "$bud_elapsed" -lt 25 ] && echo 1 || echo 0)"
contains "…then says the budget is spent" "$(cat "$FIX/bud.out")" "budget for this stop is spent"
rtmux kill-server >/dev/null 2>&1

echo "the budget bounds the WAITING, and never cuts the asking short"
# ── THE CONTRACT, CHOSEN DELIBERATELY ───────────────────────────────────────
#
# Codex offered two: make CL_HANDOFF_BUDGET a true whole-phase bound (stop
# dispatching once it expires), or call it a wait budget and say dispatch sits
# outside it. The first would reintroduce the exact fault this PR replaced —
# sessions that are never asked at all — so this is the second, and it is
# asserted here so a future "optimisation" to cut dispatch short fails loudly.
#
# What must NOT be unbounded is any individual send, and that is
# CL_HANDOFF_SEND_TIMEOUT's job, tested above.
reset_sessions
mk_agent AskAllA 202610121200 1 0
mk_agent AskAllB 202610121100 1 0
mk_agent AskAllC 202610121000 1 0
out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-askall" CL_HANDOFF_TIMEOUT=30 CL_HANDOFF_ATTEMPTS=1 \
  CL_HANDOFF_BUDGET=1 bash "$CL" stop --keep-tabs 2>&1)
check "a 1s budget still asks every session" "3" "$(printf '%s\n' "$out" | grep -c '→ asked')"
contains "…and clamps the WAIT to what is left" "$out" "waiting up to 1s"
rtmux kill-server >/dev/null 2>&1

echo "the transcript counts what was ASKED, not what was eligible"
# A hand-written handoff is an answer, so it is neither asked for nor counted in
# the denominator. Folding it in made "N of N landed" unreadable (Codex P3).
reset_sessions
mk_agent CountA 202610121200 1 1
mk_agent CountB 202610121100 1 0
mkdir -p "$FIX/store-count"
printf 'written by hand\n\n<!-- cl:manual:2026-10-12T00:00:00Z -->\n' > "$FIX/store-count/CountB.md"
out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-count" CL_HANDOFF_TIMEOUT=20 CL_HANDOFF_ATTEMPTS=1 \
  bash "$CL" stop --keep-tabs 2>&1)
contains "the manual one is honoured, not asked"      "$out" "wrote by hand for \"CountB\""
check "…so only the other is asked"                   "1" "$(printf '%s\n' "$out" | grep -c '→ asked')"
contains "…the announcement says 1, not 2"            "$out" "asking 1 session(s)"
contains "…and names the one it did not ask"          "$out" "1 more already answered by hand"
contains "…the tally denominator is what was asked"   "$out" "1 of 1 asked handoff(s) landed"
contains "…crediting the hand-written one separately" "$out" "1 already answered by hand"
rtmux kill-server >/dev/null 2>&1

echo "a retired setting is reported, not silently ignored"
reset_sessions
mk_agent ShareA 202610121200 1 0
out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-share" CL_HANDOFF_TIMEOUT=2 CL_HANDOFF_ATTEMPTS=1 \
  CL_HANDOFF_MIN_SHARE=45 bash "$CL" stop --keep-tabs 2>&1)
contains "CL_HANDOFF_MIN_SHARE says it no longer applies" "$out" "CL_HANDOFF_MIN_SHARE=45 no longer applies"
contains "…and says what happens instead"                 "$out" "every session gets the whole"
rtmux kill-server >/dev/null 2>&1

echo "…and nothing is said about asking when nobody will be asked"
# THE REGRESSION THIS SUITE CAUSED ONCE. An earlier version counted every claude
# session, so `--no-handoff` and a rotation-off machine announced a budget
# nobody was going to spend — test-rotate-toggle.sh caught it, because "off"
# must not even say the word "asked".
reset_sessions
mk_agent QuietA 202610121200 1 0
mk_agent QuietB 202610121100 1 0
out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-quiet" bash "$CL" stop --no-handoff --keep-tabs 2>&1)
not_contains "--no-handoff asks nobody, so it announces nothing" "$out" "asking"
not_contains "…and waits for nothing"                            "$out" "waiting up to"
# Guard: the run has to have actually walked the sessions, or both of those pass
# by describing an empty stop.
contains "the no-handoff run really did process the sessions" "$out" "QuietA"
rtmux kill-server >/dev/null 2>&1

echo "a dry run previews every ask and waits for none of them"
reset_sessions
mk_agent DryA 202610121200 1 0
mk_agent DryB 202610121100 1 0
start=$(date +%s)
out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-dry" CL_HANDOFF_TIMEOUT=60 bash "$CL" stop --dry-run 2>&1)
dry_elapsed=$(( $(date +%s) - start ))
check "both sessions are previewed" "2" "$(printf '%s\n' "$out" | grep -c 'would ask')"
not_contains "…and nothing is waited for" "$out" "waiting up to"
check "…so a dry run is immediate"  "1" "$([ "$dry_elapsed" -lt 15 ] && echo 1 || echo 0)"
# A dry run must leave no trace — the store is resolved by the read-only
# previewer, which must not create it.
check "…and no handoff store is created" "0" "$([ -d "$FIX/store-dry" ] && echo 1 || echo 0)"
check "…and both sessions are still alive" "2" \
  "$(rtmux list-sessions 2>/dev/null | grep -c '^Dry')"
rtmux kill-server >/dev/null 2>&1

echo "nothing is killed until the wait is over"
# THE CTRL-C PROPERTY. Serially, by the time session 19 was asked, sessions 1-18
# were already dead — so interrupting a slow stop lost every handoff still in
# flight. Now the first kill cannot happen before the last ask.
reset_sessions
mk_agent OrderA 202610121200 1 1
mk_agent OrderB 202610121100 1 1
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/store-ord" CL_HANDOFF_TIMEOUT=25 CL_HANDOFF_ATTEMPTS=1 \
  bash "$CL" stop --keep-tabs > "$FIX/ord.out" 2>&1
# `retire_session` prints nothing reliable, so the handoff totals line is the
# marker for "the wait is over": every ask must precede it.
last_ask=$(grep -n '→ asked'            "$FIX/ord.out" | tail -1 | cut -d: -f1)
done_line=$(grep -n 'handoff(s) landed' "$FIX/ord.out" | head -1 | cut -d: -f1)
check "the last ask precedes the end of the wait" "1" \
  "$([ -n "$last_ask" ] && [ -n "$done_line" ] && [ "$last_ask" -lt "$done_line" ] && echo 1 || echo 0)"
check "…and both sessions are gone afterwards" "0" \
  "$(rtmux list-sessions 2>/dev/null | grep -c '^Order')"
rtmux kill-server >/dev/null 2>&1

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
