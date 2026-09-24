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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
