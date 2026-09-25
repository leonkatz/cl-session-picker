#!/usr/bin/env bash
# Handoff / fresh-start / rotation-hint tests for bin/claude-session — run:
# tests/test-handoff.sh
#
# These are the pieces added for `cl stop` handoff + `cl start --fresh` +
# the `cl --list` context/rotate columns. None of them mutate a real handoff dir or
# kill a real process: every fixture is an isolated HOME (CL_HANDOFF_DIR and
# CL_HANDOFF_FALLBACK_BASE both point inside the throwaway dir), and every
# destructive path is exercised only via --dry-run or --no-handoff.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-handoff.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected output to contain [$3]"$'\n''       got: '"$2" ;; esac; }
not_contains() { case "$2" in *"$3"*) bad "$1" "expected output NOT to contain [$3]" ;; *) ok "$1" ;; esac; }

export HOME="$FIX/home"
BASEPATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$HOME/.claude/projects/p1" "$FIX/work1" "$FIX/work2"

usage_line() { # input cache_read cache_creation
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$1" "$2" "$3"
}

# --- fixture: two Claude sessions ------------------------------------------
# T-Big: last usage sums to 300000 (over the 250k rotate threshold), recent.
{
  printf '{"cwd":"%s"}\n{"customTitle":"T-Big"}\n' "$FIX/work1"
  usage_line 100000 100000 50000     # 250000, superseded below
  usage_line 200000 90000 10000      # 300000 — the one that must win (last)
} > "$HOME/.claude/projects/p1/sid-big.jsonl"
touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || date -d '-1 hour' +%Y%m%d%H%M)" "$HOME/.claude/projects/p1/sid-big.jsonl" 2>/dev/null

# T-Small: usage sums to 9000, recent — should not be flagged rotate.
{
  printf '{"cwd":"%s"}\n{"customTitle":"T-Small"}\n' "$FIX/work2"
  usage_line 5000 3000 1000
} > "$HOME/.claude/projects/p1/sid-small.jsonl"

run_list() {
  env -i HOME="$HOME" PATH="$BASEPATH" bash "$CL" --list 2>/dev/null
}

echo "context_size + rotate_hint (via --list)"
out=$(run_list)
contains "T-Big shows the LAST usage record's total (300k), not the first (250k)" "$out" "300k"
contains "T-Big is flagged rotate (over 250k threshold)" "$(printf '%s\n' "$out" | grep 'T-Big')" "rotate"
contains "T-Small shows its small total, rendered as 9k" "$out" "9k"
not_contains "T-Small is not flagged rotate" "$(printf '%s\n' "$out" | grep 'T-Small')" "rotate"

echo "rotate on age alone"
old_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_ROTATE_AGE_DAYS=0 bash "$CL" --list 2>/dev/null | grep 'T-Small')
contains "age-based rotate fires even with a small context, once the threshold is 0 days" "$old_out" "rotate"

echo "rotate never fires for Codex (start --fresh is Claude-only)"
# Round-2 Codex review: rotate_hint's AGE branch didn't know about agent, so
# an old Codex row with a blank context (context_size is intentionally blank
# for Codex) still got flagged "rotate" — recommending an action
# (`start --fresh`) that doesn't exist for Codex.
ID_OLDCODEX=01aaaaaa-0000-7000-8000-0000000000ff
mkdir -p "$HOME/.codex/sessions/2020/01/01"
export CODEX_HOME="$HOME/.codex"
printf '{"id":"%s","thread_name":"OldCodex","updated_at":"2020-01-01T00:00:00Z"}\n' "$ID_OLDCODEX" > "$CODEX_HOME/session_index.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$ID_OLDCODEX" "$FIX/work1" \
  > "$HOME/.codex/sessions/2020/01/01/rollout-2020-01-01T00-00-00-$ID_OLDCODEX.jsonl"
touch -t 202001010000 "$HOME/.codex/sessions/2020/01/01/rollout-2020-01-01T00-00-00-$ID_OLDCODEX.jsonl"
codex_rotate_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CODEX_HOME="$CODEX_HOME" bash "$CL" --list 2>/dev/null | grep OldCodex)
not_contains "an old Codex row is never flagged rotate" "$codex_rotate_out" "rotate"
rm -f "$CODEX_HOME/session_index.jsonl"; rm -rf "$HOME/.codex/sessions/2020"

echo "handoff fallback (unreachable dir)"
RO="$FIX/ro-parent"; mkdir -p "$RO"; chmod 000 "$RO"
FALLBACK="$FIX/fallback-state"
stop_out=$(env -i HOME="$HOME" PATH="$BASEPATH" \
  CL_HANDOFF_DIR="$RO/hdir" CL_HANDOFF_FALLBACK_BASE="$FALLBACK" \
  bash "$CL" stop --dry-run 2>&1)
chmod 755 "$RO"
contains "an unwritable handoff base logs the fallback, not silence" "$stop_out" "handoff dir unusable"
contains "the dry-run handoff path is under the fallback base, not the fallback dir" "$stop_out" "$FALLBACK"

echo "handoff dir success (writable dir)"
# Pre-created, like a handoff dir that has been used before — the *_preview
# resolver is read-only (never mkdir's), so an
# as-yet-nonexistent base previews as unreachable even when a real run
# would create it fine. See handoff_root_preview's comment for that tradeoff.
HDIR="$FIX/dir-ok"; mkdir -p "$HDIR"
stop_out2=$(env -i HOME="$HOME" PATH="$BASEPATH" \
  CL_HANDOFF_DIR="$HDIR" \
  bash "$CL" stop --dry-run 2>&1)
not_contains "a writable handoff base never logs a fallback notice" "$stop_out2" "handoff dir unusable"
contains "the dry-run handoff path is under the configured dir, not the fallback" "$stop_out2" "$HDIR/T-Big.md"

echo "cl stop --dry-run never touches state or kills anything"
state_exists=0; [ -e "$HOME/.config/claude-session/state.json" ] && state_exists=1
check "no state.json written by a dry-run stop" "0" "$state_exists"

echo "cl stop --no-handoff skips the handoff step entirely"
noh_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$FIX/dir-noh" \
  bash "$CL" stop --no-handoff --keep-tabs 2>&1)
not_contains "--no-handoff never asks for a handoff" "$noh_out" "asked"
not_contains "--no-handoff never mentions the handoff dir" "$noh_out" "handoff dir unusable"

echo "cl stop rejects an unrecognised flag rather than silently ignoring it"
bad_out=$(env -i HOME="$HOME" PATH="$BASEPATH" bash "$CL" stop --bogus-flag 2>&1); bad_rc=$?
check "unrecognised stop flag exits non-zero" "1" "$bad_rc"
contains "…and says which flag" "$bad_out" "--bogus-flag"

echo "the nonce-based completion check rejects both races a content hash missed"
# Round 3 Codex review: a content hash alone is not a valid completion
# signal — reproduced BOTH directions: (a) a real completed handoff whose
# bytes happen to be identical to an earlier rotation's has an UNCHANGED
# hash, so a genuine success would time out; (b) an unrelated write (or a
# File Provider reconciling mid-sync) changes the hash without this
# request's handoff having landed, so a false success would be accepted
# mid-board-trim. request_handoff's actual check — `grep -qF -- "$nonce"
# "$hp"` — is exercised directly here against both failure shapes.
NONCE_HF="$FIX/nonce-test.md"
nonce="clho:test:$$:12345:67890"
printf '# some earlier handoff\ncontent that happens to be identical later\n' > "$NONCE_HF"
premise_ok=0
grep -qF -- "$nonce" "$NONCE_HF" 2>/dev/null || premise_ok=1
check "(a) a stale, byte-identical-later handoff does NOT satisfy this request's check" "1" "$premise_ok"
printf 'totally unrelated content from something else entirely\n' > "$NONCE_HF"
unrelated_ok=0
grep -qF -- "$nonce" "$NONCE_HF" 2>/dev/null || unrelated_ok=1
check "(b) an unrelated content change without the nonce does NOT satisfy this request's check" "1" "$unrelated_ok"
printf '# real handoff\n...\n<!-- cl:%s -->\n' "$nonce" > "$NONCE_HF"
real_ok=0
grep -qF -- "$nonce" "$NONCE_HF" 2>/dev/null && real_ok=1
check "…but a real completion containing THIS request's nonce does satisfy it" "1" "$real_ok"
rm -f "$NONCE_HF"

echo "name_component: the leading-dot fix stays injective (round-3 regression)"
# Round 3 Codex review: round 2's leading-dot fix (prefix with "_") was
# ITSELF non-injective — ".foo" and "_.foo" both encoded to "_.foo". Fixed by
# encoding the dot itself ("%2E") instead of prefixing it. These pairs must
# now all differ.
name_component() { # a standalone copy of the shipped function, for direct
  # unit testing without sourcing the whole script (which runs its dispatch
  # unconditionally at the bottom) — kept byte-for-byte in sync with
  # bin/claude-session's version; if this test ever drifts from the real
  # function, the real-tmux/cmux tests above still exercise the real one
  # end-to-end.
  local n="$1" out="" c i hex
  for (( i=0; i<${#n}; i++ )); do
    c="${n:i:1}"
    case "$c" in
      /|%) printf -v c '%%%02X' "'$c" ;;
      *)
        printf -v hex '%d' "'$c" 2>/dev/null || hex=128
        if [ "$hex" -lt 32 ] || [ "$hex" -eq 127 ]; then printf -v c '%%%02X' "'$c"; fi
        ;;
    esac
    out+="$c"
  done
  case "$out" in .*) out="%2E${out#.}" ;; esac
  [ -n "$out" ] || out="_"
  printf '%s' "$out"
}
check "'.foo' vs '_.foo' no longer collide" "1" "$([ "$(name_component ".foo")" != "$(name_component "_.foo")" ] && echo 1 || echo 0)"
check "'.' vs '_.' no longer collide"       "1" "$([ "$(name_component ".")"    != "$(name_component "_.")"    ] && echo 1 || echo 0)"
check "'..' vs '_..' no longer collide"     "1" "$([ "$(name_component "..")"   != "$(name_component "_..")"   ] && echo 1 || echo 0)"
unset -f name_component

echo "handoff_root fails closed when a required subdirectory can't be created"
# Round 3 Codex review: mkdir -p's exit status was discarded, so a regular
# FILE sitting where Sessions/handoff (or the fallback base) should be a
# directory was silently accepted as a usable root.
BLOCKED_DIR="$FIX/blocked-dir"
: > "$BLOCKED_DIR"                         # a FILE where the directory belongs
BLOCKED_FALLBACK="$FIX/blocked-fallback"   # the fallback base itself is a FILE
: > "$BLOCKED_FALLBACK"
blocked_out=$(env -i HOME="$HOME" PATH="$BASEPATH" \
  CL_HANDOFF_DIR="$BLOCKED_DIR" CL_HANDOFF_FALLBACK_BASE="$BLOCKED_FALLBACK" \
  CL_HANDOFF_TIMEOUT=1 bash "$CL" stop --keep-tabs 2>&1)
contains "a blocked dir falls back, and a blocked fallback is reported as unusable, not silently accepted" \
  "$blocked_out" "no durable location available"
rm -rf "$BLOCKED_DIR" "$BLOCKED_FALLBACK"

echo "cl start --fresh (dry-run)"
fresh_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$FIX/dir-fresh" \
  bash "$CL" start --fresh "T-Big" --dry-run 2>&1)
contains "dry-run fresh-start reports what it would do, not silence" "$fresh_out" "would launch fresh"
contains "the fresh-start prompt points at the handoff path" "$fresh_out" "T-Big.md"
contains "the fresh-start prompt tells it to continue from the handoff" "$fresh_out" "then continue"
fh_exists=0; [ -e "$HOME/.config/claude-session/fresh-history.json" ] && fh_exists=1
check "dry-run never writes the fresh-history recovery log" "0" "$fh_exists"

echo "cl start --fresh refuses an unknown name"
unk_out=$(env -i HOME="$HOME" PATH="$BASEPATH" bash "$CL" start --fresh "Does Not Exist" --dry-run 2>&1); unk_rc=$?
check "unknown name exits non-zero" "1" "$unk_rc"
contains "…and says so" "$unk_out" "no claude session named"

echo "plain 'cl start' (no --fresh) is unaffected"
# The earlier --no-handoff run above was a REAL (non-dry-run) stop, so it
# legitimately saved an empty state.json (no live sessions in this fixture) —
# that's the one real write in this whole test file, and it makes "cl start"
# report an empty saved state rather than crash.
plain_out=$(env -i HOME="$HOME" PATH="$BASEPATH" bash "$CL" start 2>&1); plain_rc=$?
check "plain start exits non-zero on an empty saved state" "1" "$plain_rc"
contains "…and says so rather than crashing" "$plain_out" "saved state is empty"

# --- real-tmux fixtures ------------------------------------------------------
# TMUX_TMPDIR isolates the tmux SERVER (a distinct socket dir), not just a
# fixture HOME — real tmux, not a fake, because the bugs below are specific
# to what real tmux accepts as a send-keys target. Both the setup commands
# below and every `cl` invocation in this section must share this same
# TMUX_TMPDIR so they talk to the one throwaway server, never the user's.
TMUX_TMPDIR="$FIX/tmux-tmp"; mkdir -p "$TMUX_TMPDIR"
rtmux() { TMUX_TMPDIR="$TMUX_TMPDIR" tmux "$@"; }
cleanup_rtmux() { rtmux kill-server >/dev/null 2>&1 || true; }
trap 'cleanup_rtmux; rm -rf "$FIX"' EXIT

echo "send_text_tmux really reaches the pane (real tmux, not a fake)"
# Regression for the Codex-review finding: `send-keys -t "=name"` (no
# trailing colon) fails "can't find pane" on tmux 3.7c even though
# `has-session` accepts that exact target — an earlier fake-tmux fixture
# accepted any target and so never caught it.
RECV="$FIX/received.txt"
# The receiver reads in RAW terminal mode, byte-at-a-time — like Claude Code's
# own input box, which must be raw to render live keystrokes/arrow keys. A
# canonical-mode reader (bash's plain `read -r line`) is NOT a faithful
# stand-in here: macOS's tty line discipline caps a canonical line at ~1024
# bytes (found while writing this test — a >1024-byte literal `send-keys -l`
# landed nothing at all against a `read -r line` receiver, at any chunk size
# or pacing), while the real ~1900-byte handoff prompt arrives intact against
# a raw-mode reader in one `send-keys -l` call. The 1024-byte ceiling is a
# property of canonical mode, not of tmux or of this prompt's length.
RECEIVER="$FIX/receiver.py"
cat > "$RECEIVER" <<PYEOF
import sys, tty, termios, time
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
data = b""
try:
    while True:
        c = sys.stdin.buffer.read(1)
        if not c or c in (b"\r", b"\n"):
            break
        data += c
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
with open("$RECV", "wb") as f:
    f.write(data)
time.sleep(3)
PYEOF
rtmux new-session -d -s TmuxSendTarget -c "$FIX" "python3 $RECEIVER"
# send_text_tmux isn't independently callable (the script isn't designed to
# be sourced), so it's driven through its one real caller: request_handoff,
# via a real (non-dry-run, non-handoff) `cl stop` against a discover fixture
# that names OUR live tmux session.
printf '{"cwd":"%s"}\n{"customTitle":"TmuxSendTarget"}\n' "$FIX" > "$HOME/.claude/projects/p1/sid-tmuxsend.jsonl"
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/dir-send" CL_HANDOFF_TIMEOUT=2 \
  bash "$CL" stop --keep-tabs >/dev/null 2>&1
recv=$(cat "$RECV" 2>/dev/null || echo '')
contains "the literal prompt text really reached the pane's stdin" "$recv" "write a handoff to"
contains "…carrying THIS request's nonce, which is the completion signal" "$recv" "clho:"
# handoff_root must create handoff/ as well as the root itself — a freshly
# selected root (configured dir OR fallback) can pass the write-probe and still
# have no subdirectory, so the prompt's very first real write (to
# handoff/<name>.md) would fail on ENOENT. This real `cl stop` run just
# resolved that root for real.
handoff_dir_ok=0; [ -d "$FIX/dir-send" ] && handoff_dir_ok=1
check "handoff_root created the directory" "1" "$handoff_dir_ok"
# archive/ is deliberately NOT created: it existed for one person's note
# convention, and a shared tool should not make directories for a workflow it
# does not define.
archive_made=0; [ -d "$FIX/dir-send/archive" ] && archive_made=1
check "…and no archive/ directory for a workflow the tool does not define" "0" "$archive_made"
rtmux kill-session -t TmuxSendTarget >/dev/null 2>&1 || true
rm -f "$RECV" "$HOME/.claude/projects/p1/sid-tmuxsend.jsonl"

echo "cl stop --dry-run --no-handoff never kills (flag order/combination bug)"
# The exact combination the review's fake-tmux fixture caught: --dry-run's
# short-circuit used to live ONLY inside the no_handoff=0 branch, so
# `--dry-run --no-handoff` fell straight through to a real kill-session.
rtmux new-session -d -s DryRunProbe -c "$FIX" 'sleep 30'
printf '{"cwd":"%s"}\n{"customTitle":"DryRunProbe"}\n' "$FIX" > "$HOME/.claude/projects/p1/sid-dryrunprobe.jsonl"
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  bash "$CL" stop --dry-run --no-handoff >/dev/null 2>&1
still_alive=0; rtmux has-session -t DryRunProbe 2>/dev/null && still_alive=1
check "DryRunProbe is still alive after --dry-run --no-handoff" "1" "$still_alive"
rtmux kill-session -t DryRunProbe >/dev/null 2>&1 || true
rm -f "$HOME/.claude/projects/p1/sid-dryrunprobe.jsonl"

echo "cl start --fresh fails closed when retirement is declined (real tmux, no tty)"
# Regression for the Codex-review finding: the earlier do_fresh_start ignored
# request_handoff/kill-session/retire_process return values entirely and
# always proceeded to launch a second claude under the same name. Here the
# fixture session looks mid-task (a real `caffeinate` child, the same signal
# session_busy checks for), and the harness has no /dev/tty to answer
# "kill anyway? [y/N]" — a failed `read` leaves $ans empty, which is the
# same as answering "no": do_fresh_start must fail closed rather than launch.
# A tight busy-loop is the OTHER signal claude_busy checks (CPU >= 15%,
# alongside a caffeinate child) — simpler to reproduce faithfully than getting
# a real caffeinate into the right position in the process tree under a
# scripted pane command.
# shellcheck disable=SC2016  # single quotes are the point: this runs inside the pane's OWN shell, not this one
rtmux new-session -d -s FreshFailClosed -c "$FIX" 'i=0; while :; do i=$((i+1)); done'
sleep 1   # let CPU% ramp up before cl samples it
printf '{"cwd":"%s"}\n{"customTitle":"FreshFailClosed"}\n' "$FIX" > "$HOME/.claude/projects/p1/sid-freshfail.jsonl"
fresh_fail_out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/dir-freshfail" CL_HANDOFF_TIMEOUT=1 \
  bash "$CL" start --fresh FreshFailClosed </dev/null 2>&1)
fresh_fail_rc=$?
check "a declined/undecidable retirement exits non-zero" "1" "$fresh_fail_rc"
contains "…and says it did not start fresh" "$fresh_fail_out" "not starting fresh"
still_alive2=0; rtmux has-session -t FreshFailClosed 2>/dev/null && still_alive2=1
check "the original session is untouched — still alive" "1" "$still_alive2"
fh_written=0; [ -e "$HOME/.config/claude-session/fresh-history.json" ] \
  && grep -q FreshFailClosed "$HOME/.config/claude-session/fresh-history.json" 2>/dev/null && fh_written=1
check "…and was never recorded as retired in fresh-history.json" "0" "$fh_written"
rtmux kill-session -t FreshFailClosed >/dev/null 2>&1 || true
rm -f "$HOME/.claude/projects/p1/sid-freshfail.jsonl"

echo "cl start --fresh fails closed on a handoff timeout ALONE, even when retirement would succeed"
# Round-2 Codex review: the previous fix only checked retirement's return
# value, not request_handoff's — a REACHABLE pane that simply never writes a
# handoff (nobody home, or busy with something that never finishes) still let
# do_fresh_start retire the old session and launch a replacement anyway. This
# pane is idle (not busy), so retirement alone would succeed without even a
# prompt — proving the block comes from the missing handoff, not from a busy
# check.
rtmux new-session -d -s HandoffOnlyFail -c "$FIX" 'sleep 30'
printf '{"cwd":"%s"}\n{"customTitle":"HandoffOnlyFail"}\n' "$FIX" > "$HOME/.claude/projects/p1/sid-handoffonly.jsonl"
handoff_only_out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/dir-handoffonly" CL_HANDOFF_TIMEOUT=1 \
  bash "$CL" start --fresh HandoffOnlyFail </dev/null 2>&1)
handoff_only_rc=$?
check "a handoff that never arrives exits non-zero, even for an idle (retirable) session" "1" "$handoff_only_rc"
contains "…and says no handoff arrived" "$handoff_only_out" "no handoff arrived"
still_alive3=0; rtmux has-session -t HandoffOnlyFail 2>/dev/null && still_alive3=1
check "the original session was never retired" "1" "$still_alive3"
fh_written2=0; [ -e "$HOME/.config/claude-session/fresh-history.json" ] \
  && grep -q HandoffOnlyFail "$HOME/.config/claude-session/fresh-history.json" 2>/dev/null && fh_written2=1
check "…and was never recorded in fresh-history.json" "0" "$fh_written2"
rtmux kill-session -t HandoffOnlyFail >/dev/null 2>&1 || true
rm -f "$HOME/.claude/projects/p1/sid-handoffonly.jsonl"

cleanup_rtmux

echo "send_text_cmux uses the real 'cmux send' / 'send-key' contract"
# cmux has no 'send-text' subcommand (an earlier version of this function
# guessed one and always fell back silently). Confirmed against an installed
# cmux build (0.64.22): 'cmux send --surface <id> -- <text>' then a SEPARATE
# 'cmux send-key --surface <id> -- enter' — never relying on \n in the text,
# since `cmux send` documents \n/\r/\t in the text itself as key presses.
FIX2="$(mktemp -d "${TMPDIR:-/tmp}/cl-cmux.XXXXXX")"
mkdir -p "$FIX2/bin" "$FIX2/home/.claude/projects/p1" "$FIX2/work" "$FIX2/home/.cmuxterm"
printf '{"cwd":"%s"}\n{"customTitle":"CmuxSendTarget"}\n' "$FIX2/work" > "$FIX2/home/.claude/projects/p1/sid-cmuxsend.jsonl"
SFC="surface-under-test"
printf '{"sessions":{"sid-cmuxsend":{"surfaceId":"%s"}}}\n' "$SFC" > "$FIX2/home/.cmuxterm/claude-hook-sessions.json"
cat > "$FIX2/bin/cmux" <<CMUXFAKE
#!/bin/sh
case "\$1" in
  --help) printf '  send [flags] <text>\n  send-key [flags] <key>\n'; exit 0 ;;
  send)     shift; printf '%s\n' "\$@" > "$FIX2/argv.send"; exit 0 ;;
  send-key) shift; printf '%s\n' "\$@" > "$FIX2/argv.sendkey"; exit 0 ;;
  *) exit 1 ;;
esac
CMUXFAKE
chmod +x "$FIX2/bin/cmux"
# A fake, harmless osascript (never touches the real iTerm app) so
# send_text_iterm reliably misses instead of possibly hitting a real
# Terminal/iTerm running on this machine — same pattern test-tmux-mode.sh
# uses. jq IS real (symlinked): request_handoff needs it to read the surface
# store. Real tmux is simply absent from this PATH, so its branch can't match.
printf '#!/bin/sh\necho no\n' > "$FIX2/bin/osascript"; chmod +x "$FIX2/bin/osascript"
ln -sf "$(command -v jq)" "$FIX2/bin/jq"
# $FIX2/bin (cmux, fake osascript, jq) first, then /usr/bin:/bin for ordinary
# coreutils (grep, mkdir, date, stat, ...) that discover()/request_handoff
# call by bare name — deliberately NOT including a real tmux (Homebrew-only,
# so plain /usr/bin:/bin already excludes it).
env -i HOME="$FIX2/home" PATH="$FIX2/bin:/usr/bin:/bin" CL_HANDOFF_DIR="$FIX2/dir-cmux" CL_HANDOFF_TIMEOUT=1 \
  bash "$CL" stop --keep-tabs >/dev/null 2>&1
sendkey_ok=0; [ -e "$FIX2/argv.sendkey" ] && grep -qx "enter" "$FIX2/argv.sendkey" && sendkey_ok=1
send_ok=0; [ -e "$FIX2/argv.send" ] && grep -q -- "--surface" "$FIX2/argv.send" && grep -q "$SFC" "$FIX2/argv.send" && send_ok=1
check "cmux send was called with --surface and the recorded surface id" "1" "$send_ok"
check "cmux send-key enter was called as a SEPARATE step (never folded into the text)" "1" "$sendkey_ok"
rm -rf "$FIX2"

echo "the instruction is replaceable — the tool supplies mechanism, you supply workflow"
# The original version of this feature had one person's note-keeping rules
# typed into the script. What a session should tidy before it ends is a
# workflow; only the handoff-and-token part is the tool's business.
PROMPTS="$HOME/.config/claude-session"; mkdir -p "$PROMPTS"
PDIR="$FIX/prompt-dir"; mkdir -p "$PDIR"

default_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$PDIR" \
  CL_HANDOFF_PROMPT_FILE="$PROMPTS/does-not-exist.txt" \
  bash "$CL" start --fresh "T-Big" --dry-run 2>&1)
contains "with no custom file, the default instruction is used" "$default_out" "Read your handoff at"

printf 'CUSTOM-MARKER tidy {{name}} then write {{handoff}} with {{nonce}} under {{store}}\n' \
  > "$PROMPTS/handoff-prompt.txt"
printf 'CUSTOM-RESUME read {{handoff}} and carry on\n' > "$PROMPTS/resume-prompt.txt"
custom_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$PDIR" \
  bash "$CL" start --fresh "T-Big" --dry-run 2>&1)
contains "a custom resume prompt replaces the default outright" "$custom_out" "CUSTOM-RESUME"
not_contains "…so the default text is gone, not appended to" "$custom_out" "Read your handoff at"
contains "…with {{handoff}} substituted for the real path" "$custom_out" "$PDIR/T-Big.md"

# An empty custom file must not produce an empty instruction: typing nothing
# into a pane asks for nothing, and the stop would then wait out its whole
# timeout for a handoff no one was asked to write.
: > "$PROMPTS/resume-prompt.txt"
empty_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$PDIR" \
  bash "$CL" start --fresh "T-Big" --dry-run 2>&1)
contains "an empty custom prompt falls back to the default, never to silence" "$empty_out" "Read your handoff at"
rm -f "$PROMPTS/handoff-prompt.txt" "$PROMPTS/resume-prompt.txt"

echo "the dry run previews the same path a real run would write"
# The preview resolver is a separate code path from the real one, so the two
# can disagree — and did, when the store layout changed under a rename: the
# preview still advertised a Sessions/ level the real resolver had dropped.
PV="$FIX/preview-agree"; mkdir -p "$PV"
prev=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$PV" \
  bash "$CL" stop --dry-run 2>&1 | grep -o "$PV[^ ]*T-Big.md" | head -1)
env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$PV" CL_HANDOFF_TIMEOUT=1 \
  bash "$CL" stop --keep-tabs >/dev/null 2>&1
real_dir_ok=0; [ -d "$PV" ] && real_dir_ok=1
check "a real run creates the directory the preview named" "1" "$real_dir_ok"
check "…and the previewed path sits inside it" "1" \
  "$(printf '%s' "$prev" | grep -c "^$PV/")"

echo "prompt construction: one literal line, literal substitution, refused without a token"
# These go at the builder directly. The end-to-end dry-run path returns before
# a prompt is ever built, so driving these through it would assert nothing —
# and the properties here are exactly the ones that were wrong.
PROMPTS="$HOME/.config/claude-session"; mkdir -p "$PROMPTS"
BUILD="$FIX/build.sh"
{ grep '^_prompt_flatten() {' "$CL"                 # a one-liner: match the line
  sed -n '/^_prompt_expand/,/^}$/p'      "$CL"
  sed -n '/^read_prompt_file/,/^}$/p'    "$CL"
  sed -n '/^build_resume_prompt/,/^}$/p' "$CL"
  sed -n '/^build_handoff_prompt/,/^}$/p' "$CL"
} > "$BUILD"
printf 'handoff_path() { printf "%%s/%%s.md" "$1" "$2"; }\n' >> "$BUILD"
bp() { env CL_HANDOFF_PROMPT_FILE="${1:-/nonexistent}" CL_RESUME_PROMPT_FILE=/nonexistent \
        bash -c "source '$BUILD'; build_handoff_prompt \"\$@\"" _ "$2" "$3" "$4" 2>"$FIX/bp.err"; }

# A CRLF file keeps one CR per line after tr '\n'; cmux reads CR as Enter, and
# a tab is a real Tab keystroke.
printf 'one {{nonce}}\r\ntwo\tafter tab {{handoff}}\r\n' > "$PROMPTS/handoff-prompt.txt"
out=$(bp "$PROMPTS/handoff-prompt.txt" /store Name clho:1:1:1:1)
check "a CRLF template yields no carriage return" "0" "$(printf '%s' "$out" | LC_ALL=C grep -c $'\r')"
check "…and no literal tab"                       "0" "$(printf '%s' "$out" | LC_ALL=C grep -c $'\t')"
check "…and is a single line"                     "0" "$(printf '%s' "$out" | grep -c '^$')"

# A control character arriving through a SUBSTITUTED VALUE is the case that
# flattening the template alone never sees.
printf 'x {{nonce}} {{name}} y\n' > "$PROMPTS/handoff-prompt.txt"
out=$(bp "$PROMPTS/handoff-prompt.txt" /store "$(printf 'Bad\rName')" clho:1:1:1:1)
check "a control character inside a value is folded too" "0" \
  "$(printf '%s' "$out" | LC_ALL=C grep -c $'\r')"

# Sequential ${var//} passes rescan what earlier passes inserted.
printf 'H={{handoff}} N={{nonce}} A={{name}} S={{store}}\n' > "$PROMPTS/handoff-prompt.txt"
out=$(bp "$PROMPTS/handoff-prompt.txt" /the-store '{{store}}-and-{{nonce}}' clho:7:7:7:7)
contains "a value spelling {{store}} is inserted verbatim" "$out" 'A={{store}}-and-{{nonce}}'
check "…never expanded into the real store path" "0" "$(printf '%s' "$out" | grep -c 'A=/the-store')"
check "…and never rewritten into the nonce"      "1" "$(printf '%s' "$out" | grep -c 'and-{{nonce}}')"

# A prompt that never asks for the token can never be confirmed: sending it
# costs every session the full timeout on a statically visible mistake.
printf 'tidy up and write something to {{handoff}}\n' > "$PROMPTS/handoff-prompt.txt"
out=$(bp "$PROMPTS/handoff-prompt.txt" /store Name clho:2:2:2:2)
err=$(cat "$FIX/bp.err")
contains "a prompt with no {{nonce}} is refused" "$err" "no {{nonce}} placeholder"
not_contains "…and its text is never used"       "$out" "tidy up"
contains "…the built-in default is sent instead" "$out" "Before you stop: write a handoff"
rm -f "$PROMPTS/handoff-prompt.txt"

# The default is what strangers inherit. An earlier "generic" default still
# carried a line-count target and a prescribed schema while the docs claimed it
# defined nothing beyond the token. Asserted here rather than through
# `--fresh --dry-run`, which prints the RESUME prompt and returns before a
# handoff prompt is ever built — so those assertions held whatever it said.
out=$(bp /nonexistent /store Name clho:3:3:3:3)
not_contains "the default prescribes no line count" "$out" "100 lines"
not_contains "…and no content schema"              "$out" "gotchas"
not_contains "…and no list of what to cover"       "$out" "in-flight work"
contains     "…it asks for the handoff"            "$out" "write a handoff"
contains     "…and for the token"                  "$out" "clho:3:3:3:3"

echo "the fallback is write-probed, not just stat'd"
# The primary gets a real write probe; the fallback used to get [ -d ] only —
# on exactly the path taken when the primary has already failed.
RO2="$FIX/ro-fallback"; mkdir -p "$RO2/primary" "$RO2/fb"
chmod 555 "$RO2/primary"      # primary exists but rejects writes -> fall back
chmod 555 "$RO2/fb"           # fallback exists, is a dir, and ALSO rejects writes
fb_out=$(env -i HOME="$HOME" PATH="$BASEPATH" \
  CL_HANDOFF_DIR="$RO2/primary" CL_HANDOFF_FALLBACK_BASE="$RO2/fb" \
  CL_HANDOFF_TIMEOUT=1 bash "$CL" stop --keep-tabs 2>&1)
chmod 755 "$RO2/primary" "$RO2/fb"
contains "an unwritable fallback is reported, not accepted" "$fb_out" "no durable handoff location"

echo "dry run and a real run agree on a first install"
# The preview used to require the directory to already exist, so on a fresh
# machine it announced the fallback while the real run created and used the
# configured default — the divergence that matters most, on first use.
NEW="$FIX/never-used/handoff"          # does not exist; its parent is writable
NUFB="$FIX/nu-fallback"
new_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$NEW" \
  CL_HANDOFF_FALLBACK_BASE="$NUFB" bash "$CL" stop --dry-run 2>&1)
contains "the previewed path is under the configured dir" "$new_out" "$NEW/T-Big.md"
not_contains "…a creatable dir is not announced as unusable" "$new_out" "handoff dir unusable"
not_contains "…and the fallback is not named"               "$new_out" "nu-fallback"
check "…while the dry run still creates nothing" "0" "$([ -e "$NEW" ] && echo 1 || echo 0)"
# And prove the preview told the truth: a real run uses that same path.
env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$NEW" \
  CL_HANDOFF_FALLBACK_BASE="$NUFB" CL_HANDOFF_TIMEOUT=1 \
  bash "$CL" stop --keep-tabs >/dev/null 2>&1
check "a real first run creates and uses exactly that dir" "1" "$([ -d "$NEW" ] && echo 1 || echo 0)"
check "…and never falls back"                              "0" "$([ -e "$NUFB" ] && echo 1 || echo 0)"


# ===========================================================================
# Rotation: the handoff as the hinge between two runs.
# ===========================================================================
# `cl stop` writes it, `cl start` rotates off it. The invariant everything
# below rests on: AT MOST ONE UNCONSUMED HANDOFF PER SESSION — so the mere
# presence of the file means "written, not yet used".
#
# These drive the NO-TMUX shape on purpose: nothing is pre-created there, so
# `cl start` has to carry the decision into the tab command, where it is
# visible to a test without launching a single agent. PATH excludes tmux so
# use_tmux() is false; jq is symlinked in because do_start requires it.
NOTMUX="$FIX/notmux-bin"; mkdir -p "$NOTMUX"
ln -sf "$(command -v jq)" "$NOTMUX/jq" 2>/dev/null
NOTMUX_PATH="$NOTMUX:/usr/bin:/bin"
STATEDIR="$HOME/.config/claude-session"; mkdir -p "$STATEDIR"
RDIR="$FIX/rot-store"

write_state() { # name sid cwd
  printf '[{"name":"%s","sid":"%s","cwd":"%s"}]\n' "$1" "$2" "$3" > "$STATEDIR/state.json"
}
run_start() { env -i HOME="$HOME" PATH="$NOTMUX_PATH" CL_HANDOFF_DIR="$RDIR" \
  CL_HANDOFF_FALLBACK_BASE="$FIX/rot-fb" bash "$CL" start 2>&1; }
consumed_count() { ls "$RDIR/consumed" 2>/dev/null | grep -c . ; }

echo "cl start rotates a session that has an unconsumed handoff"
mkdir -p "$RDIR"
printf 'work in flight\n<!-- cl:clho:1:1:1:1 -->\n' > "$RDIR/T-Big.md"
write_state "T-Big" "sid-big" "$FIX/work1"
rot_out=$(run_start)
contains "the tab command says to start fresh from the handoff" "$rot_out" "--rotate-from"
contains "…and it is announced, not silent"                     "$rot_out" "will start fresh"
check "…the handoff is no longer sitting unconsumed" "0" "$([ -e "$RDIR/T-Big.md" ] && echo 1 || echo 0)"
check "…it moved to consumed/, it was not deleted"   "1" "$(consumed_count)"
contains "…and the rotate-from path points INTO consumed/" "$rot_out" "consumed/"

echo "…and the OLD session id is recorded, so a rotation is never a dead end"
check "fresh-history records the retired session" "1" \
  "$(grep -c 'sid-big' "$STATEDIR/fresh-history.json" 2>/dev/null || echo 0)"

echo "a SECOND cl start does not rotate again — the handoff was consumed"
# The trap this invariant exists to close: with nothing consuming the file,
# every start from here on would rotate off the same ever-staler handoff, and
# `--no-handoff` would quietly stop meaning anything.
write_state "T-Big" "sid-big" "$FIX/work1"
again_out=$(run_start)
not_contains "no rotation the second time"        "$again_out" "--rotate-from"
contains     "…it resumes the session instead"    "$again_out" 'cl "T-Big"'
check "…and nothing new was consumed" "1" "$(consumed_count)"

echo "no handoff at all means resume — nothing is lost"
# The floor the whole design stands on: a skipped, failed or impossible
# handoff leaves no file, and the session comes back whole.
rm -f "$RDIR/T-Small.md"
write_state "T-Small" "sid-small" "$FIX/work2"
plain_out=$(run_start)
not_contains "a session with no handoff is not rotated" "$plain_out" "--rotate-from"
contains     "…it comes back by name"                   "$plain_out" 'cl "T-Small"'

echo "a handoff that cannot be cleared does not rotate"
# Rotating off a file we failed to move means rotating off it again every
# start, forever. Declining degrades to a plain resume, which loses nothing.
# The store itself must stay writable — making it read-only would fail the
# root probe instead and silently fall back, testing the wrong branch. A plain
# FILE where consumed/ needs to be makes the MOVE fail and nothing else.
RO3="$FIX/rot-ro"; mkdir -p "$RO3"
printf 'stuck\n<!-- cl:clho:9:9:9:9 -->\n' > "$RO3/T-Big.md"
: > "$RO3/consumed"
write_state "T-Big" "sid-big" "$FIX/work1"
stuck_out=$(env -i HOME="$HOME" PATH="$NOTMUX_PATH" CL_HANDOFF_DIR="$RO3" \
  CL_HANDOFF_FALLBACK_BASE="$FIX/rot-fb2" bash "$CL" start 2>&1)
not_contains "an unmovable handoff is not rotated off" "$stuck_out" "--rotate-from"
contains     "…and the reason is reported"             "$stuck_out" "not rotating it"
contains     "…while the session still comes back"     "$stuck_out" 'cl "T-Big"'
check "…and the handoff is left where it is, not lost" "1" "$([ -f "$RO3/T-Big.md" ] && echo 1 || echo 0)"

# ===========================================================================
# cl stop fails CLOSED.
# ===========================================================================
echo "cl stop leaves a session running when no handoff lands"
# The inversion: stopping without a handoff silently turns a rotation into a
# plain resume. Leaving it alive keeps both options open and costs a tab.
rtmux new-session -d -s KeepAlive -c "$FIX" 'sleep 30'
printf '{"cwd":"%s"}\n{"customTitle":"KeepAlive"}\n' "$FIX" > "$HOME/.claude/projects/p1/sid-keepalive.jsonl"
keep_out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$FIX/keep-store" CL_HANDOFF_TIMEOUT=1 CL_HANDOFF_ATTEMPTS=2 \
  bash "$CL" stop --keep-tabs 2>&1)
alive=0; rtmux has-session -t KeepAlive 2>/dev/null && alive=1
check "the session is still alive after a failed handoff" "1" "$alive"
contains "…and the refusal says so"           "$keep_out" "leaving \"KeepAlive\" running"
contains "…naming the way out"                "$keep_out" "cl handoff"
contains "…and the other way out"             "$keep_out" "--no-handoff"
contains "…it is asked more than once"        "$keep_out" "attempt 2 of 2"

echo "…but --no-handoff still stops it"
# Fail-closed must not become a wedge: the deliberate skip has to still work.
env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  bash "$CL" stop --keep-tabs --no-handoff >/dev/null 2>&1
alive2=0; rtmux has-session -t KeepAlive 2>/dev/null && alive2=1
check "--no-handoff stops a session that has no handoff" "0" "$alive2"
rtmux kill-session -t KeepAlive >/dev/null 2>&1 || true
rm -f "$HOME/.claude/projects/p1/sid-keepalive.jsonl"

# ===========================================================================
# The hand-written escape hatch.
# ===========================================================================
echo "cl handoff writes a handoff from inside a session"
HDIR2="$FIX/manual-store"; mkdir -p "$HDIR2"
man_path=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$HDIR2" \
  CL_SESSION_NAME="T-Big" bash "$CL" handoff --path 2>/dev/null)
check "--path prints the path it would write" "$HDIR2/T-Big.md" "$man_path"
printf 'hand written state\n' | env -i HOME="$HOME" PATH="$BASEPATH" \
  CL_HANDOFF_DIR="$HDIR2" CL_SESSION_NAME="T-Big" bash "$CL" handoff >/dev/null 2>&1
check "piping content in writes the file" "1" "$([ -f "$HDIR2/T-Big.md" ] && echo 1 || echo 0)"
contains "…keeping what was piped in" "$(cat "$HDIR2/T-Big.md" 2>/dev/null)" "hand written state"
contains "…and stamping it as hand-written" "$(cat "$HDIR2/T-Big.md" 2>/dev/null)" "<!-- cl:manual:"

echo "…an empty handoff is refused, not written"
# An empty file would satisfy every existence check while saying nothing.
rm -f "$HDIR2/T-Empty.md"
empty_rc=0
printf '' | env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$HDIR2" \
  CL_SESSION_NAME="T-Empty" bash "$CL" handoff >/dev/null 2>&1 || empty_rc=$?
check "an empty pipe is rejected"        "1" "$empty_rc"
check "…and no file is left behind"      "0" "$([ -e "$HDIR2/T-Empty.md" ] && echo 1 || echo 0)"

echo "…and without a name it says so rather than guessing"
noname_out=$(env -i HOME="$HOME" PATH="$BASEPATH" CL_HANDOFF_DIR="$HDIR2" \
  bash "$CL" handoff --path 2>&1) || true
contains "no CL_SESSION_NAME is an error, not a guess" "$noname_out" "no session name"

echo "a hand-written handoff is honoured by cl stop instead of asking"
# The whole reason `cl stop` can afford to fail closed: there is a way to
# satisfy it when the pane cannot be reached at all.
rtmux new-session -d -s ManualTarget -c "$FIX" 'sleep 30'
printf '{"cwd":"%s"}\n{"customTitle":"ManualTarget"}\n' "$FIX" > "$HOME/.claude/projects/p1/sid-manual.jsonl"
MSTORE="$FIX/manual-honour"; mkdir -p "$MSTORE"
printf 'written by hand\n<!-- cl:manual:2026-09-24T00:00:00Z -->\n' > "$MSTORE/ManualTarget.md"
man_out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$MSTORE" CL_HANDOFF_TIMEOUT=1 bash "$CL" stop --keep-tabs 2>&1)
contains "the hand-written handoff is used"        "$man_out" "handoff you wrote by hand"
contains "…with its age, so an old one is obvious" "$man_out" "ago"
not_contains "…and the pane is never asked"        "$man_out" "attempt 1 of"
check "…the file is left for cl start to consume" "1" "$([ -f "$MSTORE/ManualTarget.md" ] && echo 1 || echo 0)"
# The other half of the contract: fail-closed only refuses when the handoff is
# MISSING. Once it is satisfied, the stop proceeds exactly as it always did.
man_alive=0; rtmux has-session -t ManualTarget 2>/dev/null && man_alive=1
check "…and the session IS stopped once the handoff is satisfied" "0" "$man_alive"
rtmux kill-session -t ManualTarget >/dev/null 2>&1 || true

echo "a superseded nonce handoff is swept before a new one is requested"
# Left by a --no-handoff stop or a crash. It must not be able to satisfy the
# wait below, or a stop would confirm itself off a file from weeks ago.
rtmux new-session -d -s SweepTarget -c "$FIX" 'sleep 30'
printf '{"cwd":"%s"}\n{"customTitle":"SweepTarget"}\n' "$FIX" > "$HOME/.claude/projects/p1/sid-sweep.jsonl"
SSTORE="$FIX/sweep-store"; mkdir -p "$SSTORE"
printf 'old cycle\n<!-- cl:clho:0:0:0:0 -->\n' > "$SSTORE/SweepTarget.md"
sweep_out=$(env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
  CL_HANDOFF_DIR="$SSTORE" CL_HANDOFF_TIMEOUT=1 CL_HANDOFF_ATTEMPTS=1 \
  bash "$CL" stop --keep-tabs 2>&1)
contains "the leftover is swept"                "$sweep_out" "superseded"
check "…out of the way"  "0" "$([ -e "$SSTORE/SweepTarget.md" ] && echo 1 || echo 0)"
check "…into consumed/"  "1" "$(ls "$SSTORE/consumed" 2>/dev/null | grep -c .)"
contains "…and a fresh request is made anyway"  "$sweep_out" "attempt 1 of"
rtmux kill-session -t SweepTarget >/dev/null 2>&1 || true
rm -f "$HOME/.claude/projects/p1/sid-manual.jsonl" "$HOME/.claude/projects/p1/sid-sweep.jsonl"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
