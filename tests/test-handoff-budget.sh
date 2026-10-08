#!/usr/bin/env bash
# Handoff budget fairness + busy-awareness tests — run: tests/test-handoff-budget.sh
#
# ── WHAT WENT WRONG ─────────────────────────────────────────────────────────
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
# Two independent defects, neither of which is a submit bug — a 427-character
# single-line prompt followed immediately by Enter was measured submitting
# correctly into an idle session:
#
# 1. A BUSY claude QUEUES typed input and runs it when it finishes. Measured:
#    injecting into a working session shows "Press up to edit queued messages"
#    and executes nothing until the current task ends. cl saw no handoff file,
#    concluded the ask was lost, and typed it AGAIN — three copies stacked in
#    one input box. A retry answers "the ask did not land", which is not the
#    same question as "the agent has not finished".
#
# 2. ARITHMETIC: CL_HANDOFF_ATTEMPTS(3) × CL_HANDOFF_TIMEOUT(90) = 270s against
#    a CL_HANDOFF_BUDGET of 300s for the WHOLE stop. One session's worst case
#    was 90% of everyone's budget. That is not a cap.
#
# So the properties under test are: a working session is waited for and NOT
# re-asked, no session can spend more than its share, and an operator is told
# BEFORE the stop that the budget will not cover the sessions they have.
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

# The REAL functions, verbatim — same extractor the sibling suite uses, because
# a reimplementation here would only prove the reimplementation works. The
# shape-tracking awk matters: a one-liner definition breaks a naive sed range.
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
extract_fns "$CL" handoff_session_cap handoff_target_busy handoff_nonce request_handoff > "$LIB"
for fn in handoff_session_cap handoff_target_busy handoff_nonce request_handoff; do
  grep -q "^${fn}()" "$LIB" || setup_failed "could not extract ${fn} from the shipped script"
done
# A guard on the extract, not on the product: if request_handoff ever stops
# consulting the busy check or the cap, these tests must fail loudly rather
# than keep passing against a function that no longer has the behaviour.
grep -q 'handoff_target_busy' "$LIB" || setup_failed "extracted request_handoff never consults the busy check"
grep -q '_CL_SESSION_CAP'     "$LIB" || setup_failed "extracted request_handoff never consults the session cap"

echo "handoff_session_cap divides the budget, with a floor that can still succeed"
cap() { ( CL_HANDOFF_MIN_SHARE="${3:-45}"; . "$LIB"; handoff_session_cap "$1" "$2" ); }
check "one session gets the lot"                        "300" "$(cap 300 1)"
check "two split it"                                    "150" "$(cap 300 2)"
# THE WORK MAC'S CASE: 300/19 = 15s, which is below the ~35s a real handoff
# takes. A 15s ask is not a short ask, it is a guaranteed failure that still
# spends the budget — so the floor wins over fairness here on purpose.
check "nineteen would get 15s, so the floor applies" "45"  "$(cap 300 19)"
check "…and the floor is configurable"               "20"  "$(cap 300 19 20)"
# Clamped the other way too: the floor must never promise more than is left.
check "the floor never exceeds what is left"         "30"  "$(cap 30 1)"
check "a divisor of zero is treated as one, not a division error" "300" "$(cap 300 0)"
check "exactly at the floor is not rounded up"       "45"  "$(cap 90 2)"

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
# The iTerm/cmux case: no tmux session, so the recorded pid is the only handle.
check "no tmux but a recorded pid mid-task is busy"    "busy" "$(tb 1 1 4242 0)"
check "…and no pid at all is not busy, not an error"   "idle" "$(tb 1 1 '' 0)"

# ── the behavioural core ────────────────────────────────────────────────────
# request_handoff driven with stubs, because a real busy claude cannot be
# fixtured. SENDS ARE COUNTED IN A FILE: the function runs in a subshell, so a
# counter variable would be lost — the same out-param-through-a-subshell trap
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
    tmux() { case "$1" in has-session) return 0 ;; esac; return 1; }
    send_text_tmux() { printf '%s\n' "$2" >> "$SENDS"; return 0; }
    request_handoff "Target" "sid-1" "$FIX" "tname" ""
  ) > "$FIX/rh.out" 2>&1
  echo $?
}
sends()  { grep -c . "$SENDS" 2>/dev/null || echo 0; }
nonces() { sed -n 's/.*nonce=//p' "$SENDS" | sort -u | grep -c . || echo 0; }

echo "a session that is still WORKING is waited for, not asked again"
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

echo "no session can spend more than its share of the stop"
start=$(date +%s)
rc=$(run_rh 1 3 2 1)   # cap 1s, but 3 attempts × 2s = 6s if uncapped
elapsed=$(( $(date +%s) - start ))
check "it stops at the cap instead of taking every attempt" "1" "$([ "$elapsed" -lt 5 ] && echo 1 || echo 0)"
contains "…and says whose share ran out" "$(cat "$FIX/rh.out")" "used its 1s share"
check "…returning 'no handoff' so the caller resumes as-is" "2" "$rc"
# Uncapped must still behave as before, or the cap has quietly become mandatory.
start=$(date +%s)
run_rh 1 2 2 -1 >/dev/null
check "an uncapped caller still uses its full attempts" "1" \
  "$([ $(( $(date +%s) - start )) -ge 3 ] && echo 1 || echo 0)"

echo "the operator is warned BEFORE the stop, not after the losses"
# End-to-end through the real `cl stop --dry-run`, against a discover fixture —
# the warning is worth nothing if it only exists in a unit test, and --dry-run
# is exactly where it should be readable while it is still free to act on.
export HOME="$FIX/home"
BASEPATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$HOME/.claude/projects/p1" "$HOME/.config/claude-session" || setup_failed "fixture HOME"
make_sessions() { # <n>
  rm -f "$HOME/.claude/projects/p1/"*.jsonl
  local i
  for i in $(seq 1 "$1"); do
    printf '{"cwd":"%s"}\n{"customTitle":"Probe%s"}\n' "$FIX" "$i" \
      > "$HOME/.claude/projects/p1/sid-probe$i.jsonl"
  done
}
stop_dry() { env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$FIX/hdir" \
  CL_HANDOFF_BUDGET="${1:-300}" bash "$CL" stop --dry-run 2>&1; }

make_sessions 19
out="$(stop_dry 300)"
# A guard first: if the fixture produced no sessions, every assertion below
# would pass by describing nothing.
contains "the fixture really produced sessions to stop" "$out" "Probe"
contains "nineteen sessions on a 300s budget is called out"  "$out" "19 sessions share a 300s handoff budget"
contains "…naming the share each would get"                  "$out" "15s each"
contains "…and how many can actually be asked"               "$out" "About 6 will be asked"
contains "…with the exact command that would cover them all" "$out" "CL_HANDOFF_BUDGET=855"

echo "…and stays quiet when the budget is adequate"
# A warning that fires always is a warning nobody reads.
make_sessions 2
out="$(stop_dry 300)"
not_contains "two sessions on 300s draws no warning" "$out" "handoff budget —"
make_sessions 1
out="$(stop_dry 300)"
not_contains "a single session never divides the budget at all" "$out" "sessions share"

echo "…and never warns about a budget nobody is going to spend"
# THE REGRESSION THIS SUITE CAUSED. The first version counted every claude
# session, so a machine with rotation off, or `--no-handoff`, warned that a
# budget was too small for sessions it was never going to ask — and
# test-rotate-toggle.sh caught it, because "off" must not even say the word
# "asked". The count and the loop now share one resolver.
make_sessions 19
out="$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$FIX/hdir" \
  CL_HANDOFF_BUDGET=300 bash "$CL" stop --dry-run --no-handoff 2>&1)"
not_contains "--no-handoff asks nobody, so it warns about nothing" "$out" "sessions share"
not_contains "…and does not say 'asked' at all" "$out" "will be asked"
# Guard: the run has to have actually walked the sessions, or both of those
# pass by describing an empty stop.
contains "the no-handoff run really did process the sessions" "$out" "Probe"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
