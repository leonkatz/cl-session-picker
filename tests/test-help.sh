#!/usr/bin/env bash
# `cl --help` and `cl stop --help` — run: tests/test-help.sh
#
# Help used to be the script's 113-line header comment, so `--no-handoff` sat
# mid-paragraph and a cmux removal note was the last thing printed. It is now a
# curated text; these tests keep it honest: every flag `cl stop` accepts is
# listed, nothing it does not accept is, and asking for help changes nothing.
set -u
CL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-help.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$2" in *"$3"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s\n       wanted [%s] in: %s\n' "$1" "$3" "$2" ;; esac; }
cl() { env -i HOME="$FIX/home" PATH="/usr/bin:/bin" TERM_PROGRAM= bash "$CL" "$@" 2>&1; }
mkdir -p "$FIX/home"

printf 'cl --help\n'
out=$(cl --help); rc=$?
check "exits 0" "0" "$rc"
has "names cl stop" "$out" "cl stop [flags]"
has "points at the stop flags, naming --no-handoff" "$out" "cl stop --help"
has "…and --no-handoff itself" "$out" "--no-handoff"
check "no cmux" "0" "$(printf '%s' "$out" | grep -ci cmux)"
check "short enough to read (< 40 lines)" "1" "$([ "$(printf '%s\n' "$out" | wc -l)" -lt 40 ] && echo 1 || echo 0)"

printf 'cl stop --help\n'
out=$(cl stop --help); rc=$?
check "exits 0" "0" "$rc"
# Every flag the parser accepts, read from the parser itself, must be listed —
# and every flag listed must be one the parser accepts.
# Short flags too (-h): a long-only pattern silently skipped them.
accepted=$(awk '/^do_stop\(\)/,/^}/' "$CL" | grep -oE '^ +-{1,2}[a-z][a-z-]*(\|-{1,2}[a-z][a-z-]*)*\)' | tr -d ' )' | tr '|' '\n' | sort -u)
[ -n "$accepted" ] || { echo "FIXTURE: could not read the stop flags from the parser" >&2; exit 2; }
for f in $accepted; do has "lists $f" "$out" "$f"; done
listed=$(printf '%s\n' "$out" | grep -oE '(^|[ (,])-{1,2}[a-z][a-z-]*' | tr -d ' (,' | sort -u)
for f in $listed; do
  printf '%s\n' "$accepted" | grep -qxF -- "$f" && { pass=$((pass+1)); printf '  ok   %s\n' "$f is a real stop flag"; } \
    || { fail=$((fail+1)); printf '  FAIL %s\n' "$f is listed but cl stop does not accept it"; }
done
check "asking for help stopped nothing and saved nothing" "0" "$(find "$FIX/home" -type f | wc -l | tr -d ' ')"

printf 'help needs no runtime prerequisite\n'
# stop needs jq to work, but not to explain itself: a machine missing jq is
# exactly where someone reaches for --help.
mkdir -p "$FIX/nojq"
for t in bash sh env cat awk sed grep tr sort head tail wc date mkdir dirname basename uname id ps pgrep; do
  p=$(command -v "$t") && ln -sf "$p" "$FIX/nojq/$t"
done
out=$(env -i HOME="$FIX/home" PATH="$FIX/nojq" TERM_PROGRAM= "$FIX/nojq/bash" "$CL" stop --help 2>&1); rc=$?
check "cl stop --help works with no jq on PATH" "0" "$rc"
has "…and prints the help" "$out" "--no-handoff"
out=$(env -i HOME="$FIX/home" PATH="$FIX/nojq" TERM_PROGRAM= "$FIX/nojq/bash" "$CL" stop --dry-run 2>&1); rc=$?
check "control: an actual stop without jq still refuses" "1" "$rc"

printf 'an unknown stop flag points at the help\n'
out=$(cl stop --bogus); rc=$?
check "exits 1" "1" "$rc"
has "…naming cl stop --help" "$out" "cl stop --help"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
