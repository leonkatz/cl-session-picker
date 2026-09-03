#!/usr/bin/env bash
# Argv-level regression for the Codex launch grammar — run: tests/test-launch-args.sh
#
# The property (not a string grep): resuming a Codex session executes
#   codex [<CL_CODEX_ARGS words>] resume <id>
# with the top-level args BEFORE the subcommand, the id as ONE argv element,
# and nothing added when CL_CODEX_ARGS is empty. Proven by fake codex/cmux
# binaries that record their real argv. Some Codex builds reject top-level
# options placed after `resume`; this pins the grammar every build accepts.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-args.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }

# One discoverable Codex session.
export HOME="$FIX/home"; export CODEX_HOME="$HOME/.codex"
SID=01aaaaaa-0000-7000-8000-0000000000aa
mkdir -p "$CODEX_HOME/sessions/2026/01/01" "$FIX/work" "$FIX/bin"
printf '{"id":"%s","thread_name":"T","updated_at":"2026-01-01T00:00:00Z"}\n' "$SID" > "$CODEX_HOME/session_index.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$SID" "$FIX/work" > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$SID.jsonl"

# Fake binaries that record argv, one element per line.
mk_fake() { printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s"\nexit 0\n' "$2" > "$FIX/bin/$1"; chmod +x "$FIX/bin/$1"; }
mk_fake codex "$FIX/argv.codex"
# PATH strips tmux so launch execs codex directly; keep core utils.
BASEPATH="$FIX/bin:/usr/bin:/bin"

run_cl() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$BASEPATH" ${1:+CL_CODEX_ARGS="$1"} bash "$CL" --codex T >/dev/null 2>&1 ); }

echo "direct (no tmux, no cmux)"
run_cl '--approve-for-me'
check "argv = --approve-for-me resume <id>" "--approve-for-me|resume|$SID" "$(paste -sd'|' - < "$FIX/argv.codex")"
run_cl ''
check "empty CL_CODEX_ARGS adds nothing" "resume|$SID" "$(paste -sd'|' - < "$FIX/argv.codex")"
run_cl '-m gpt-5 --approve-for-me'
check "multi-word args stay separate elements, before the subcommand" "-m|gpt-5|--approve-for-me|resume|$SID" "$(paste -sd'|' - < "$FIX/argv.codex")"

echo "cmux (codex-teams wrapper)"
cat > "$FIX/bin/cmux" <<CMUX
#!/bin/sh
case "\$1" in
  --help) echo "  codex-teams [codex-args...]"; exit 0 ;;
  rename-tab) exit 0 ;;
  codex-teams) shift; for a in "\$@"; do printf '%s\n' "\$a"; done > "$FIX/argv.cmux"; exit 0 ;;
esac
exit 0
CMUX
chmod +x "$FIX/bin/cmux"
( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$BASEPATH" CMUX_SURFACE_ID=x CL_CODEX_ARGS='--approve-for-me' bash "$CL" --codex T >/dev/null 2>&1 )
check "cmux path forwards the same grammar to codex-teams" "--approve-for-me|resume|$SID" "$(paste -sd'|' - < "$FIX/argv.cmux")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
