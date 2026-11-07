#!/usr/bin/env bash
# `cl compact` — run: tests/test-compact-cmd.sh
#
# Steps 2-5 of compact-resume (docs/restart-modes.md) without a stop: the
# pre-compact request, /compact once the cl-done reply lands, a confirmed
# compaction. The checks are the stop's own (compact_phase), so what this suite
# adds is what is DIFFERENT about the command:
#
#   * the session keeps running — never stopped, killed, saved, or re-moded;
#   * the fallbacks lead nowhere: no token means /compact is never typed, no
#     boundary means it is reported and never typed again;
#   * targets are named or --all, Codex is skipped, a target that is not
#     running is reported, and any target not confirmed compacted makes the
#     exit non-zero.
#
# The simulated agent is test-compact-resume.sh's own, read out of that file,
# so both suites drive exactly the same transcript tail Claude Code writes.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-compactcmd.XXXXXX")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "wanted [$3] in: $2" ;; esac; }
not_contains() { case "$2" in *"$3"*) bad "$1" "did NOT want [$3] in: $2" ;; *) ok "$1" ;; esac; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || setup_failed "jq is required by the code under test"
command -v tmux >/dev/null 2>&1 || setup_failed "tmux is needed to drive a simulated agent"
command -v python3 >/dev/null 2>&1 || setup_failed "python3 runs the simulated agent"

export HOME="$FIX/home"
BASEPATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
PROJ="$HOME/.claude/projects/p1"
STATEDIR="$HOME/.config/claude-session"
CODEXDIR="$HOME/.codex"
mkdir -p "$PROJ" "$STATEDIR" "$FIX/work" || setup_failed "fixture HOME"
# A private tmux server: nothing here can reach a real session's pane.
TMUX_TMPDIR="$FIX/tmux-tmp"; mkdir -p "$TMUX_TMPDIR"
rtmux() { TMUX_TMPDIR="$TMUX_TMPDIR" tmux "$@"; }
trap 'rtmux kill-server >/dev/null 2>&1; rm -rf "$FIX"' EXIT

AGENT="$FIX/agent.py"
awk '/^cat > "\$AGENT" <<'"'"'PYEOF'"'"'$/{f=1; next} f && /^PYEOF$/{exit} f{print}' \
  "$HERE/test-compact-resume.sh" > "$AGENT"
grep -q 'compact_boundary' "$AGENT" || setup_failed "could not read the simulated agent out of test-compact-resume.sh"

mk_agent() { # <name> <sid> <mode> [delay]
  printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX/work" "$1" > "$PROJ/$2.jsonl"
  rtmux new-session -d -s "$1" -c "$FIX" \
    "AGENT_MODE='$3' AGENT_DELAY='${4:-0.5}' AGENT_TRANSCRIPT='$PROJ/$2.jsonl' AGENT_RECV='$FIX/recv-$1.txt' exec python3 '$AGENT'" 2>/dev/null \
    || setup_failed "could not start the agent for $1"
}
# A Claude session cl knows (it has a named transcript) that is not running.
mk_dormant() { printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX/work" "$1" > "$PROJ/$2.jsonl"; }
# A running Codex thread cl owns: a rollout and a name in Codex's index, and a
# tmux session stamped the way cl stamps its own. The pane runs the simulated
# agent so that anything typed into it would be recorded.
CXID="0a1b2c3d-1111-2222-3333-444455556666"
mk_codex() { # <name>
  mkdir -p "$CODEXDIR/sessions/2026/01/01"
  printf '{"type":"session_meta","payload":{"cwd":"%s"},"cwd":"%s"}\n' "$FIX/work" "$FIX/work" \
    > "$CODEXDIR/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$CXID.jsonl"
  printf '{"id":"%s","thread_name":"%s","updated_at":"2026-01-01T00:00:00Z"}\n' "$CXID" "$1" > "$CODEXDIR/session_index.jsonl"
  rtmux new-session -d -s "codex_$1" -c "$FIX" \
    "AGENT_MODE=ok AGENT_TRANSCRIPT='$FIX/codex-tr.jsonl' AGENT_RECV='$FIX/recv-codex_$1.txt' exec python3 '$AGENT'" 2>/dev/null \
    || setup_failed "could not start the codex stand-in"
  rtmux set-option -t "=codex_$1:" @cl_agent codex >/dev/null
  rtmux set-option -t "=codex_$1:" @cl_sid "$CXID" >/dev/null
}
reset() {
  rtmux kill-server >/dev/null 2>&1
  rm -f "$PROJ"/*.jsonl "$FIX"/recv-*.txt "$FIX/codex-tr.jsonl" "$STATEDIR"/*.json "$STATEDIR"/*.tsv
  rm -rf "$CODEXDIR" "$FIX/store"
}
compact_run() { # <out-file> [extra env...] -- [compact args...]
  local out="$1"; shift
  local -a envs=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")
  # No controlling terminal, as in test-compact-resume.sh: anything that tried
  # to prompt would be declined rather than hang the suite.
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" CL_HANDOFF_DIR="$FIX/store" \
    CL_HANDOFF_VERIFY=2 CL_COMPACT_TIMEOUT=20 \
    ${envs[@]+"${envs[@]}"} bash "$CL" compact ${args[@]+"${args[@]}"} > "$out" 2>&1 < /dev/null
  echo $? > "$out.rc"
}
typed_compact() { grep -c '^/compact$' "$FIX/recv-$1.txt" 2>/dev/null | tr -d ' '; }
nlines() { if [ -f "$1" ]; then grep -c . "$1" | tr -d ' '; else echo 0; fi; }
boundaries() { grep -c '"compact_boundary"' "$PROJ/$1.jsonl" 2>/dev/null | tr -d ' '; }
pane_pid() { rtmux list-panes -t "=$1" -F '#{pane_pid}' 2>/dev/null | head -1; }
running() { rtmux has-session -t "=$1" 2>/dev/null && kill -0 "$(pane_pid "$1")" 2>/dev/null && echo 1 || echo 0; }

# ── refusals ─────────────────────────────────────────────────────────────────
echo "no target is refused"
reset
compact_run "$FIX/none.out"
check "exits non-zero" "1" "$(cat "$FIX/none.out.rc")"
contains "…saying to name a session or use --all" "$(cat "$FIX/none.out")" "Name one or more, or use --all"
compact_run "$FIX/both.out" -- --all Foo
check "names and --all together are refused" "1" "$(cat "$FIX/both.out.rc")"
compact_run "$FIX/flag.out" -- --bogus
check "an unknown flag is refused" "1" "$(cat "$FIX/flag.out.rc")"
contains "…pointing at the help" "$(cat "$FIX/flag.out")" "cl compact --help"
out=$(env -i HOME="$HOME" PATH="$BASEPATH" bash "$CL" compact --help 2>&1); rc=$?
check "cl compact --help exits 0" "0" "$rc"
contains "…and names --all" "$out" "--all"
contains "cl --help lists cl compact" "$(env -i HOME="$HOME" PATH="$BASEPATH" bash "$CL" --help 2>&1)" "cl compact"

# ── the happy path, one session ──────────────────────────────────────────────
echo "one named session is compacted, and keeps running"
reset
mk_agent One sid-one ok
# A saved row and a mode the command must leave exactly as they are.
printf '[{"name":"One","sid":"sid-one","cwd":"%s","agent":"claude","mode":"handoff"}]\n' "$FIX/work" > "$STATEDIR/state.json"
printf '{"sessions":{"claude":{"One":"handoff"}}}\n' > "$STATEDIR/rotate.json"
cp "$STATEDIR/state.json" "$FIX/state.before"; cp "$STATEDIR/rotate.json" "$FIX/rotate.before"
pid_before=$(pane_pid One)
compact_run "$FIX/one.out" -- One
one="$(cat "$FIX/one.out")"
check "exits 0" "0" "$(cat "$FIX/one.out.rc")"
check "it was asked once" "1" "$(grep -c 'pre-compact request in' "$FIX/recv-One.txt")"
contains "…by a pointer that names cl compact" "$(cat "$FIX/recv-One.txt")" "cl compact: read and follow the pre-compact request in \"$FIX/store/One.precompact\""
contains "…whose request asks for the exact token as the last line" "$(cat "$PROJ/sid-one.jsonl")" "last line is exactly cl-done:"
contains "…and says the session keeps running" "$(cat "$PROJ/sid-one.jsonl")" "will keep running afterwards"
not_contains "…not that it is about to be restarted" "$(cat "$PROJ/sid-one.jsonl")" "compacted and restarted"
check "/compact was typed exactly once" "1" "$(typed_compact One)"
check "the request file is cleared once answered" "0" "$([ -e "$FIX/store/One.precompact" ] && echo 1 || echo 0)"
contains "the report names the path and the boundary's figures" "$one" "✓ One: compacted by /compact, 968000 → 22000 tokens"
not_contains "no handoff is asked for" "$one" "handoff request"
check "the session is still running" "1" "$(running One)"
check "…the very same process" "$pid_before" "$(pane_pid One)"
check "nothing else was typed into it" "2" "$(nlines "$FIX/recv-One.txt")"
check "the saved row is byte-identical" "1" "$(cmp -s "$FIX/state.before" "$STATEDIR/state.json" && echo 1 || echo 0)"
check "the stored mode is byte-identical" "1" "$(cmp -s "$FIX/rotate.before" "$STATEDIR/rotate.json" && echo 1 || echo 0)"
check "no state history snapshot was taken" "0" "$(ls "$STATEDIR"/history 2>/dev/null | grep -c .)"
check "nothing goes in the rotation log" "0" "$([ -e "$STATEDIR/rotation-log.tsv" ] && echo 1 || echo 0)"
not_contains "nothing is saved" "$one" "saved "

echo "with no saved state at all, none is created"
reset
mk_agent Bare sid-bare ok
compact_run "$FIX/bare.out" -- Bare
check "compacted" "0" "$(cat "$FIX/bare.out.rc")"
check "…and no state.json appears" "0" "$([ -e "$STATEDIR/state.json" ] && echo 1 || echo 0)"

# ── --all, several sessions in one window ────────────────────────────────────
echo "--all compacts every running Claude session in ONE window"
reset
mk_agent CompA sid-ca ok 2
mk_agent CompB sid-cb ok 2
mk_agent CompC sid-cc ok 2
mk_dormant Dormant sid-do
mk_codex Cx
start=$(date +%s)
compact_run "$FIX/all.out" -- --all
all_elapsed=$(( $(date +%s) - start ))
all="$(cat "$FIX/all.out")"
check "exits 0" "0" "$(cat "$FIX/all.out.rc")"
check "one window for all three" "1" "$(grep -c 'asking 3 session(s) to finish up, then /compact, all at once' "$FIX/all.out")"
last_ask=$(grep -n 'to finish up before /compact' "$FIX/all.out" | tail -1 | cut -d: -f1)
first_compact=$(grep -n 'typed /compact' "$FIX/all.out" | head -1 | cut -d: -f1)
check "…every ask goes out before any /compact is typed" "1" \
  "$([ -n "$last_ask" ] && [ -n "$first_compact" ] && [ "$last_ask" -lt "$first_compact" ] && echo 1 || echo 0)"
check "each was typed /compact exactly once" "1 1 1" "$(typed_compact CompA) $(typed_compact CompB) $(typed_compact CompC)"
check "each is reported compacted with its figures" "3" "$(grep -c '^✓ Comp[ABC]: compacted by /compact, 968000 → 22000 tokens$' "$FIX/all.out")"
# Each agent takes ~2s for its turn and ~2s to compact: serially that is 12s+.
check "three sessions cost about one window, not three (${all_elapsed}s)" "1" "$([ "$all_elapsed" -lt 14 ] && echo 1 || echo 0)"
check "all three are still running" "1 1 1" "$(running CompA) $(running CompB) $(running CompC)"
contains "the running Codex session is skipped with a note" "$all" "skipping Codex session(s) — compaction is Claude-only: Cx"
check "…and nothing is typed into it" "0" "$(nlines "$FIX/recv-codex_Cx.txt")"
check "…and it is still running" "1" "$(running codex_Cx)"
not_contains "a session that is not running is not a target of --all" "$all" "Dormant"

echo "--all with no running Claude session"
reset
mk_dormant Dormant sid-do
compact_run "$FIX/allnone.out" -- --all
check "exits 0: there was nothing to do" "0" "$(cat "$FIX/allnone.out.rc")"
contains "…and says so" "$(cat "$FIX/allnone.out")" "no running Claude sessions to compact"

# ── a boundary BEFORE /compact ───────────────────────────────────────────────
echo "an auto compaction during the pre-compact turn: already compacted"
reset
mk_agent AutoPre sid-ap auto-before
compact_run "$FIX/autopre.out" -- AutoPre
autopre="$(cat "$FIX/autopre.out")"
check "exits 0" "0" "$(cat "$FIX/autopre.out.rc")"
check "/compact is never typed" "0" "$(typed_compact AutoPre)"
check "…so it compacted exactly once" "1" "$(boundaries sid-ap)"
contains "the report says it was already compacted, with that boundary's figures" "$autopre" \
  "✓ AutoPre: already compacted (on its own, before /compact), 990000 → 21000 tokens"
check "it is still running" "1" "$(running AutoPre)"

# ── no token in time ─────────────────────────────────────────────────────────
echo "no cl-done reply: not compacted, and nothing more is done"
reset
mk_agent Silent sid-si silent
compact_run "$FIX/silent.out" CL_COMPACT_TIMEOUT=4 -- Silent
silent="$(cat "$FIX/silent.out")"
check "exits non-zero" "1" "$(cat "$FIX/silent.out.rc")"
check "/compact is never typed" "0" "$(typed_compact Silent)"
contains "the report says it did not finish its turn" "$silent" "✗ Silent: did not finish its turn; not compacted"
not_contains "no handoff is asked for" "$silent" "handoff"
check "only the one ask was typed" "1" "$(nlines "$FIX/recv-Silent.txt")"
check "the request file is cleared" "0" "$([ -e "$FIX/store/Silent.precompact" ] && echo 1 || echo 0)"
check "it is still running" "1" "$(running Silent)"

echo "…nor is a token inside a tool_result the end of the turn"
reset
mk_agent ToolRes sid-tr toolresult-only
compact_run "$FIX/toolres.out" CL_COMPACT_TIMEOUT=4 -- ToolRes
check "/compact is never typed" "0" "$(typed_compact ToolRes)"
contains "…not compacted" "$(cat "$FIX/toolres.out")" "✗ ToolRes: did not finish its turn; not compacted"

# ── no boundary after /compact ───────────────────────────────────────────────
echo "no boundary after /compact: not confirmed, and /compact is not retyped"
reset
mk_agent NoB sid-nb no-boundary
compact_run "$FIX/nob.out" CL_COMPACT_TIMEOUT=5 -- NoB
nob="$(cat "$FIX/nob.out")"
check "exits non-zero" "1" "$(cat "$FIX/nob.out.rc")"
check "/compact was typed exactly once" "1" "$(typed_compact NoB)"
contains "the report says compaction not confirmed" "$nob" "✗ NoB: compaction not confirmed"
not_contains "no handoff is asked for" "$nob" "handoff"
check "it is still running" "1" "$(running NoB)"

echo "an auto boundary after /compact does not confirm it either"
reset
mk_agent AutoPost sid-apo auto-after
compact_run "$FIX/autopost.out" CL_COMPACT_TIMEOUT=5 -- AutoPost
check "the premise: an auto boundary did land" "1" "$(boundaries sid-apo)"
contains "…and it is reported as not confirmed" "$(cat "$FIX/autopost.out")" "✗ AutoPost: compaction not confirmed"
check "…exit non-zero" "1" "$(cat "$FIX/autopost.out.rc")"

# ── targets that are not running Claude sessions ─────────────────────────────
echo "a named Codex session is skipped"
reset
mk_codex Cx
compact_run "$FIX/cx.out" -- Cx
check "exits non-zero: the named target was not compacted" "1" "$(cat "$FIX/cx.out.rc")"
contains "…saying compaction is Claude-only" "$(cat "$FIX/cx.out")" '"Cx" is a Codex session — compaction is Claude-only (skipped)'
check "nothing is typed into it" "0" "$(nlines "$FIX/recv-codex_Cx.txt")"
check "…and it is still running" "1" "$(running codex_Cx)"

echo "a named session that is not running, or unknown, is reported and skipped"
reset
mk_dormant Dormant sid-do
mk_agent Live sid-lv ok
compact_run "$FIX/mixed.out" -- Dormant Live Nobody Live
mixed="$(cat "$FIX/mixed.out")"
check "exits non-zero" "1" "$(cat "$FIX/mixed.out.rc")"
contains "the dormant one is reported not running" "$mixed" '"Dormant" is not running — nothing to compact (skipped)'
contains "an unknown name is reported" "$mixed" 'no session named "Nobody"'
contains "the running one is still compacted" "$mixed" "✓ Live: compacted by /compact"
check "…once, though it was named twice" "1 1" "$(grep -c 'pre-compact request in' "$FIX/recv-Live.txt") $(typed_compact Live)"
check "no session was started for the dormant one" "0" "$(rtmux list-sessions 2>/dev/null | grep -c '^Dormant')"

# ── dry run ──────────────────────────────────────────────────────────────────
echo "--dry-run sends nothing"
reset
mk_agent Dry sid-dr ok
mk_agent Dry2 sid-dr2 ok
compact_run "$FIX/dry.out" -- --dry-run --all
dry="$(cat "$FIX/dry.out")"
check "exits 0" "0" "$(cat "$FIX/dry.out.rc")"
check "each target is described" "2" "$(grep -c '^\[dry-run\] would ask "Dry2*" to finish its pre-compact request, type /compact once it replies, and confirm the compaction (up to 20s); it keeps running$' "$FIX/dry.out")"
sleep 1
check "nothing was typed into either" "0 0" "$(nlines "$FIX/recv-Dry.txt") $(nlines "$FIX/recv-Dry2.txt")"
check "no request file was written" "0" "$(ls "$FIX/store" 2>/dev/null | grep -c .)"
check "…and both are still running" "1 1" "$(running Dry) $(running Dry2)"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
