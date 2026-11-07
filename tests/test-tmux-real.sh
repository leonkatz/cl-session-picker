#!/usr/bin/env bash
# The ownership stamp against a REAL tmux, on a private socket.
#
# The other suites use a fake tmux that accepts any target, which is how a
# target real tmux rejects ("no such session: =name" from set-option on 3.8)
# shipped: every cl session looked unowned and the kill path refused them all.
# Skips, and says so, where tmux is not installed.
set -u
cd "$(dirname "$0")/.." || exit 2
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }

REAL_TMUX=$(command -v tmux) || { printf 'SKIP: tmux not installed\n\n0 passed, 0 failed\n'; exit 0; }
FIX=$(mktemp -d "${TMPDIR:-/tmp}/cl-tmux-real.XXXXXX") || exit 2
SOCK="cl-test-$$"
# kill-server leaves its socket file behind, so it is removed by hand.
cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"; rm -rf "$FIX"; }
trap cleanup EXIT

# Every tmux the functions run goes to the private server, never the user's.
mkdir -p "$FIX/bin"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$FIX/bin/tmux"
chmod +x "$FIX/bin/tmux"
awk '/^(tmux_claim|tmux_owned)\(\)/{p=1} p{print} p&&/^}/{p=0}' bin/claude-session > "$FIX/fns.sh"
[ "$(grep -c '^tmux_' "$FIX/fns.sh")" = 2 ] || { printf 'FIXTURE: could not extract the functions\n' >&2; exit 2; }

run() { PATH="$FIX/bin:$PATH" bash -c '. "$1"; shift; "$@"' _ "$FIX/fns.sh" "$@"; }

"$REAL_TMUX" -V
"$REAL_TMUX" -L "$SOCK" new-session -d -s "cl-probe" "sleep 60" || { printf 'FIXTURE: no tmux session\n' >&2; exit 2; }
"$REAL_TMUX" -L "$SOCK" new-session -d -s "cl-probe-other" "sleep 60" || exit 2

printf 'a session cl did not stamp\n'
run tmux_owned cl-probe claude sid-1; check "is not owned" "1" "$?"

printf 'a stamped session\n'
run tmux_claim cl-probe claude sid-1
check "the stamp is really on the session" "claude" "$("$REAL_TMUX" -L "$SOCK" show-option -qv -t "=cl-probe:" @cl_agent)"
run tmux_owned cl-probe claude sid-1; check "is owned for its agent and thread" "0" "$?"
run tmux_owned cl-probe claude;       check "…and for its agent alone" "0" "$?"
run tmux_owned cl-probe codex sid-1;  check "not for another agent" "1" "$?"
run tmux_owned cl-probe claude sid-2; check "not for another thread" "1" "$?"

printf 'exact names only\n'
# Without "=", tmux matches a name that does not exist as a prefix of one that
# does, so a gone session would answer with its longer neighbour's stamp.
run tmux_claim cl-probe-other claude sid-1
"$REAL_TMUX" -L "$SOCK" kill-session -t "=cl-probe" || exit 2
run tmux_owned cl-probe claude sid-1; check "a gone session is not owned through a longer name's stamp" "1" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
