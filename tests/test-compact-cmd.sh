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

# Process identity. cl reads a process's real image and argv from the kernel
# (proc_identity), so the Python stand-in agent is — correctly — not Claude by
# its argv. It is tied the way a real Claude session also is: Claude Code's own
# registry entry for its pid ($HOME/.claude/sessions/<pid>.json), which cl's
# production check validates field by field. Where argv identity itself is
# under test, a cc-built stand-in executable named claude (lib-fake-claude.sh)
# runs in the pane as a child of the pane's process, beside the agent.
SESSDIR="$HOME/.claude/sessions"
. "$HERE/lib-fake-claude.sh"
need_fake_claude "$FIX/fake/claude"
mk_agent() { # <name> <sid> <mode> [delay]
  # Bound as cl's own sessions are: Claude's registry places the session's
  # process in the pane, and the session is stamped as tmux_claim does.
  mk_pane "$1" "$2" "$3" "${4:-0.5}"
  reg_claude "$SESSDIR" "$(pane_pid "$1")" "$2" || setup_failed "could not register $1"
  stamp "$1" claude "$2"
}
mk_pane() { # <name> <sid> <mode> [delay] [extra agent argv]: an UNSTAMPED, UNTIED pane
  # MK_CHILD: a command started in the pane first, as a child of the pane's
  # process (which then becomes the agent) — how a stand-in Claude executable
  # sits in the pane the agent's input goes to.
  printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX/work" "$1" > "$PROJ/$2.jsonl"
  rtmux new-session -d -s "$1" -c "$FIX" \
    "${MK_CHILD:+$MK_CHILD </dev/null >/dev/null 2>&1 & }AGENT_MODE='$3' AGENT_DELAY='${4:-0.5}' AGENT_TRANSCRIPT='$PROJ/$2.jsonl' AGENT_RECV='$FIX/recv-$1.txt' exec python3 '$AGENT' ${5:-}" 2>/dev/null \
    || setup_failed "could not start the agent for $1"
}
stamp() { rtmux set-option -t "=$1:" @cl_agent "$2" >/dev/null && rtmux set-option -t "=$1:" @cl_sid "$3" >/dev/null \
  || setup_failed "could not stamp $1"; }
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
  pkill -f "^$FIX/(fake|fakenode|share)/" 2>/dev/null
  rm -f "$PROJ"/*.jsonl "$FIX"/recv-*.txt "$FIX/codex-tr.jsonl" "$STATEDIR"/*.json "$STATEDIR"/*.tsv
  rm -rf "$CODEXDIR" "$FIX/store" "$SESSDIR"
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

echo "an auto compaction and NO token: already compacted, turn unfinished"
reset
mk_agent AutoSil sid-as auto-silent
compact_run "$FIX/autosil.out" CL_COMPACT_TIMEOUT=4 -- AutoSil
autosil="$(cat "$FIX/autosil.out")"
check "exits 0: the compaction the command is for did happen" "0" "$(cat "$FIX/autosil.out.rc")"
check "/compact is never typed" "0" "$(typed_compact AutoSil)"
check "…so it compacted exactly once" "1" "$(boundaries sid-as)"
contains "the report says so, with that boundary's figures" "$autosil" \
  "✓ AutoSil: already compacted (on its own, before /compact; its turn had not finished), 990000 → 21000 tokens"
check "it is still running" "1" "$(running AutoSil)"

# ── the token must be the end of the final reply ─────────────────────────────
echo "the token predicate, on the exact near-misses"
PRED="$FIX/pred.sh"
{ awk '/^_tail_records\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$CL"
  awk '/^_CL_JQ_COMPACTED=/{f=1} f{print} f && /;.$/{exit}' "$CL"
  awk '/^_CL_JQ_TOKEN_FINAL=/{f=1} f{print} f && /;.$/{exit}' "$CL"
  awk '/^compact_token_seen\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$CL"
  awk '/^compact_idle_record\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$CL"; } > "$PRED"
grep -q '^compact_idle_record()' "$PRED" && grep -q '^_CL_JQ_TOKEN_FINAL=' "$PRED" || setup_failed "could not extract the token predicates"
pred() { # <case> <records> -> "token idle"
  printf '%s\n' "$2" > "$FIX/pred.jsonl"
  ( . "$PRED"
    compact_token_seen "$FIX/pred.jsonl"$'\t'0 cl-done:123; a=$?
    compact_idle_record "$FIX/pred.jsonl"$'\t'0 cl-done:123; printf '%s %s' "$a" "$?" )
}
A='{"type":"assistant","message":{"content":'
check "the token as the final line of a finished reply counts (both predicates)" "0 0" \
  "$(pred ok "$A"'[{"type":"text","text":"Workflow done.\ncl-done:123\n"}]}}')"
check "\"I will end with cl-done:N\" then more text does not" "1 1" \
  "$(pred midline "$A"'[{"type":"text","text":"I will end with cl-done:123\nStill working, not finished."}]}}')"
check "…nor the token mid-sentence" "1 1" \
  "$(pred midsentence "$A"'[{"type":"text","text":"The requested marker is cl-done:123. Still working; this is not my final reply."}]}}')"
check "a tool_use BEFORE the token text, in one record, does not" "1 1" \
  "$(pred toolfirst "$A"'[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 60"}},{"type":"text","text":"cl-done:123"}]}}')"
check "a tool_use AFTER it, in one record, does not" "1 1" \
  "$(pred toolafter "$A"'[{"type":"text","text":"cl-done:123"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}')"
check "a tool_use in an earlier record of the same reply does not" "1 1" \
  "$(pred split "$A"'[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}'$'\n'"$A"'[{"type":"text","text":"cl-done:123"}]}}')"
check "…but one answered by a tool_result before the reply does" "0 0" \
  "$(pred answered "$A"'[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}'$'\n''{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}'$'\n'"$A"'[{"type":"text","text":"ok\ncl-done:123"}]}}')"
check "a longer token is not this one" "1 1" "$(pred longer "$A"'[{"type":"text","text":"cl-done:1234"}]}}')"

echo "a token that is not the last line: /compact is never typed"
reset
mk_agent MidLine sid-ml token-midline
compact_run "$FIX/midline.out" CL_COMPACT_TIMEOUT=4 -- MidLine
check "/compact is never typed" "0" "$(typed_compact MidLine)"
contains "…not compacted" "$(cat "$FIX/midline.out")" "✗ MidLine: did not finish its turn; not compacted"
echo "a tool call then the token in one record: /compact is never typed"
reset
mk_agent ToolText sid-tx tool-then-text
compact_run "$FIX/tooltext.out" CL_COMPACT_TIMEOUT=4 -- ToolText
check "/compact is never typed" "0" "$(typed_compact ToolText)"
contains "…not compacted" "$(cat "$FIX/tooltext.out")" "✗ ToolText: did not finish its turn; not compacted"

# ── the pane must provably be the session ────────────────────────────────────
echo "a pane stamped as a Codex session, at a Claude session's name, gets nothing"
reset
mk_agent Collision sid-stale ok
stamp Collision codex "$CXID"
compact_run "$FIX/collision.out" -- --all
collision="$(cat "$FIX/collision.out")"
check "nothing is typed into it" "0" "$(nlines "$FIX/recv-Collision.txt")"
contains "it says why" "$collision" '"Collision": the tmux session at Collision is stamped as a codex session — not typing into it; not compacted'
contains "…and reports it" "$collision" "✗ Collision: its pane belongs to another session; nothing typed, not compacted"
check "…exit non-zero" "1" "$(cat "$FIX/collision.out.rc")"
check "no request file is left behind" "0" "$(ls "$FIX/store" 2>/dev/null | grep -c .)"

echo "a pane stamped as ANOTHER Claude session gets nothing"
reset
mk_agent Other sid-mine ok
stamp Other claude sid-someone-else
compact_run "$FIX/other.out" -- Other
check "nothing is typed into it" "0" "$(nlines "$FIX/recv-Other.txt")"
contains "it says why" "$(cat "$FIX/other.out")" "stamped as another session (sid-someone-else)"
check "…exit non-zero" "1" "$(cat "$FIX/other.out.rc")"

echo "a session stamped Claude before its id was known (cl new) still needs the process"
reset
mk_agent Newish sid-new ok
stamp Newish claude -
compact_run "$FIX/newish.out" -- Newish
contains "with the process tied to its id in the pane, it is compacted" "$(cat "$FIX/newish.out")" "✓ Newish: compacted by /compact"
reset
mk_pane NewLoose sid-newloose ok
stamp NewLoose claude -
compact_run "$FIX/newloose.out" -- NewLoose
check "without it, nothing is typed: the stamp proves a launch, not this transcript" "0" "$(nlines "$FIX/recv-NewLoose.txt")"
contains "…refused as unverified" "$(cat "$FIX/newloose.out")" "✗ NewLoose: its pane could not be verified"

echo "an unstamped pane whose process cannot be tied to the session gets nothing"
reset
mk_pane Loose sid-loose ok
compact_run "$FIX/loose.out" -- Loose
check "nothing is typed into it" "0" "$(nlines "$FIX/recv-Loose.txt")"
contains "it says why" "$(cat "$FIX/loose.out")" "cannot verify that any pane of the tmux session at Loose runs this session"
contains "…and reports it" "$(cat "$FIX/loose.out")" "✗ Loose: its pane could not be verified as this session"
check "…exit non-zero" "1" "$(cat "$FIX/loose.out.rc")"

echo "an unstamped pane running the process tied to the session's id is allowed"
reset
mk_pane Tied sid-tied ok
reg_claude "$SESSDIR" "$(pane_pid Tied)" sid-tied || setup_failed "register Tied"
compact_run "$FIX/tied.out" -- Tied
contains "it is compacted (a claude cl did not start, tied by Claude's registry)" "$(cat "$FIX/tied.out")" "✓ Tied: compacted by /compact"
check "…with exactly one /compact" "1" "$(typed_compact Tied)"
echo "…but the same process in a DIFFERENT pane does not vouch for this one"
reset
mk_agent First sid-first ok
mk_pane Elsewhere sid-else ok
mk_pane Decoy sid-decoy silent
reg_claude "$SESSDIR" "$(pane_pid Decoy)" sid-else || setup_failed "register Decoy"
compact_run "$FIX/else.out" -- Elsewhere
check "nothing is typed into the pane at the name" "0" "$(nlines "$FIX/recv-Elsewhere.txt")"
contains "…refused as unverified" "$(cat "$FIX/else.out")" "✗ Elsewhere: its pane could not be verified"

echo "the pane is checked again before /compact"
reset
mk_agent Swap sid-swap ok 3
( compact_run "$FIX/swap.out" -- Swap ) &
swap_job=$!
for (( w=0; w<80; w++ )); do [ -s "$FIX/recv-Swap.txt" ] && break; sleep 0.1; done
check "the premise: the request arrived" "1" "$(nlines "$FIX/recv-Swap.txt")"
stamp Swap codex "$CXID"
wait "$swap_job"
check "/compact is never typed into the re-stamped pane" "0" "$(typed_compact Swap)"
contains "…it says why" "$(cat "$FIX/swap.out")" '"Swap": the tmux session at Swap is stamped as a codex session — not typing into it'
check "…exit non-zero" "1" "$(cat "$FIX/swap.out.rc")"
check "…and its request file is cleared" "0" "$([ -e "$FIX/store/Swap.precompact" ] && echo 1 || echo 0)"

echo "a second, ACTIVE window in a stamped session gets nothing (review repro)"
# The stamp is session-scoped: "=Owned:" is whichever pane has focus. Here that
# is `cat`; the text must go to the agent's own pane, by its id.
reset
mk_agent Owned sid-owner ok
rtmux new-window -t '=Owned:' -n unrelated 'cat'
compact_run "$FIX/owned.out" CL_COMPACT_TIMEOUT=10 -- Owned
check "the agent's pane got the request and /compact" "2 1" "$(nlines "$FIX/recv-Owned.txt") $(typed_compact Owned)"
check "the active window got nothing" "" "$(rtmux capture-pane -p -t '=Owned:unrelated' | tr -d '[:space:]')"
contains "…and it is compacted" "$(cat "$FIX/owned.out")" "✓ Owned: compacted by /compact"

echo "a focus switch between the request and /compact does not redirect it"
reset
mk_agent Focus sid-focus ok 3
( compact_run "$FIX/focus.out" -- Focus ) &
focus_job=$!
for (( w=0; w<80; w++ )); do [ -s "$FIX/recv-Focus.txt" ] && break; sleep 0.1; done
check "the premise: the request arrived" "1" "$(nlines "$FIX/recv-Focus.txt")"
rtmux new-window -t '=Focus:' -n stolen 'cat'
wait "$focus_job"
check "/compact went to the agent's pane" "1" "$(typed_compact Focus)"
check "…and nothing into the window that took focus" "" "$(rtmux capture-pane -p -t '=Focus:stolen' | tr -d '[:space:]')"
contains "…compacted" "$(cat "$FIX/focus.out")" "✓ Focus: compacted by /compact"

echo "a refusal before any token was issued deletes no request (review repro)"
reset
mk_pane Loose sid-loose ok
mkdir -p "$FIX/store"; printf 'another run, cl-done:other-run\n' > "$FIX/store/Loose.precompact"
compact_run "$FIX/loose2.out" -- Loose
contains "the premise: it was refused before asking" "$(cat "$FIX/loose2.out")" "✗ Loose: its pane could not be verified"
check "another run's request is left exactly as it was" "another run, cl-done:other-run" "$(cat "$FIX/store/Loose.precompact" 2>/dev/null)"

# ── the bare route: no tmux session, a tagged iTerm window ───────────────────
# Real iTerm tabs are never driven here. A stand-in osascript records the
# script it is given and answers "no" (no such tagged window), so what is
# checked is what cl would ask iTerm to verify before typing.
FAKEOSA="$FIX/fakeosa"; mkdir -p "$FAKEOSA"
printf '#!/bin/sh\ncat > "%s/osa-script.txt"\necho no\n' "$FIX" > "$FAKEOSA/osascript"; chmod +x "$FAKEOSA/osascript"
echo "the bare route binds the tagged window to the session process's tty"
reset; rm -f "$FIX/osa-script.txt"
mk_agent Host sid-host ok
printf '{"cwd":"%s"}\n{"customTitle":"Bare"}\n' "$FIX/work" > "$PROJ/sid-bare.jsonl"
# The session's process, on a terminal, under ANOTHER tmux name: no tmux
# session at "Bare", so the iTerm route is the one taken.
rtmux new-window -t '=Host:' -n bare "exec python3 -c 'import time; time.sleep(120)'"
sleep 0.5
reg_claude "$SESSDIR" "$(rtmux display-message -p -t '=Host:bare' '#{pane_pid}')" sid-bare || setup_failed "register Bare"
bare_tty=$(rtmux display-message -p -t '=Host:bare' '#{pane_tty}')
compact_run "$FIX/bare.out" PATH="$FAKEOSA:$BASEPATH" -- Bare
contains "iTerm is asked to type only into a tagged window on that tty" "$(cat "$FIX/osa-script.txt" 2>/dev/null)" \
  "if \"$bare_tty\" is not \"\" and (tty of hit) is not \"$bare_tty\" then return \"mismatch\""
contains "…and with no such window, nothing is compacted" "$(cat "$FIX/bare.out")" "✗ Bare: no reachable pane; not compacted"
echo "a tied process with no terminal is refused before iTerm is asked"
reset; rm -f "$FIX/osa-script.txt"
printf '{"cwd":"%s"}\n{"customTitle":"NoTty"}\n' "$FIX/work" > "$PROJ/sid-notty.jsonl"
python3 -c 'import os, sys, time; os.setsid(); time.sleep(60)' </dev/null >/dev/null 2>&1 &
notty_pid=$!
sleep 0.5
reg_claude "$SESSDIR" "$notty_pid" sid-notty || setup_failed "register NoTty"
compact_run "$FIX/notty.out" PATH="$FAKEOSA:$BASEPATH" -- NoTty
kill "$notty_pid" 2>/dev/null; wait "$notty_pid" 2>/dev/null
contains "it is refused as unverified" "$(cat "$FIX/notty.out")" "✗ NoTty: its pane could not be verified"
check "…and iTerm was never asked" "0" "$([ -e "$FIX/osa-script.txt" ] && echo 1 || echo 0)"

# ── process identity: who counts as this session's Claude ────────────────────
LIBALL="$FIX/lib-all.sh"
sed '/^# Optional agent filter for direct launch/,$d' "$CL" > "$LIBALL"
grep -q '^proc_identity()' "$LIBALL" || setup_failed "could not read the script's functions"
argv_ok() { ( . "$LIBALL" 2>/dev/null; _claude_argv_session "$1" "$2"; echo $? ) }
CLI="$FIX/nm/@anthropic-ai/claude-code/cli.js"
mkdir -p "$(dirname "$CLI")" "$FIX/npmbin"
printf '// stand-in\n' > "$CLI"; printf '// not claude\n' > "$FIX/other.js"
ln -sf "$CLI" "$FIX/npmbin/claude"
need_fake_claude "$FIX/share/claude/versions/2.1.319"
need_fake_claude "$FIX/fakenode/node"
NODE="$FIX/fakenode/node"
"$FIX/fake/claude" --resume sid-x </dev/null >/dev/null 2>&1 & p_native=$!
"$FIX/share/claude/versions/2.1.319" --session-id sid-x </dev/null >/dev/null 2>&1 & p_versions=$!
"$NODE" "$CLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node=$!
"$NODE" "$FIX/npmbin/claude" --resume sid-x </dev/null >/dev/null 2>&1 & p_nodebin=$!
"$NODE" -e 'x' -- "$CLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node_e=$!
"$NODE" -p 'x' "$CLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node_p=$!
"$NODE" --require "$FIX/other.js" "$CLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node_req=$!
"$NODE" "$FIX/other.js" "$CLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node_other=$!
"$NODE" --no-warnings "$CLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node_flag=$!
"$NODE" -- "$CLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node_dd=$!
# Two directories, one relative entry name: launched in A, where ./entry is
# some other script; verified from B, where ./entry is Claude Code's cli.js.
mkdir -p "$FIX/relA" "$FIX/relB"
ln -sf "$FIX/other.js" "$FIX/relA/entry"; ln -sf "$CLI" "$FIX/relB/entry"
( cd "$FIX/relA" && exec "$NODE" ./entry --resume sid-x ) </dev/null >/dev/null 2>&1 & p_node_rel=$!
# An absolute, launcher-SHAPED path that is a symlink to some other script:
# only a successful resolution can tell it from the real thing.
FAKECLI="$FIX/lookalike/@anthropic-ai/claude-code/cli.js"
mkdir -p "$(dirname "$FAKECLI")"; ln -sf "$FIX/other.js" "$FAKECLI"
"$NODE" "$FAKECLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_node_look=$!
# PATHs for the resolver cases: everything the check needs except a working
# realpath — none at all, or one that fails (with or without printing the
# launcher path).
for d in norp rpfail rpfailquiet; do
  mkdir -p "$FIX/$d"
  for tool in python3 mktemp rm; do ln -sf "$(command -v "$tool")" "$FIX/$d/$tool"; done
done
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit 1\n' "$CLI" > "$FIX/rpfail/realpath"
printf '#!/bin/sh\nexit 1\n' > "$FIX/rpfailquiet/realpath"
chmod +x "$FIX/rpfail/realpath" "$FIX/rpfailquiet/realpath"
argv_ok_path() { ( . "$LIBALL" 2>/dev/null; PATH="$1"; _claude_argv_session "$2" "$3"; echo $? ) }
# An EMPTY argv[0]: a parser that strips "all the NULs" after the exec path
# eats it, every argument shifts down one, and node seems to run cli.js when
# it runs other.js.
( exec -a '' "$NODE" "$FIX/other.js" "$CLI" --resume sid-x ) </dev/null >/dev/null 2>&1 & p_argv0e=$!
( exec -a 'node' "$NODE" "$FIX/other.js" "$CLI" --resume sid-x ) </dev/null >/dev/null 2>&1 & p_argv0n=$!
p_realargv0=""
if command -v node >/dev/null 2>&1; then
  ( exec -a '' node "$FIX/other.js" "$CLI" --resume sid-x ) </dev/null >/dev/null 2>&1 & p_realargv0=$!
fi
"$FIX/fake/claude" -p -- --resume sid-x </dev/null >/dev/null 2>&1 & p_dd_prompt=$!
"$FIX/fake/claude" --resume sid-x --resume sid-other </dev/null >/dev/null 2>&1 & p_two=$!
"$FIX/fake/claude" --session-id sid-x --resume sid-other </dev/null >/dev/null 2>&1 & p_two_mixed=$!
"$FIX/fake/claude" --resume sid-x -- --resume sid-other </dev/null >/dev/null 2>&1 & p_after_dd=$!
# Every other way the CLI selects a session, beside a correct --resume <sid>.
p_sel=""; sel_forms=""
for form in "-r sid-other" "-rsid-other" "--resume=sid-other" "--session-id=sid-other" "-c" "--continue"; do
  # shellcheck disable=SC2086
  "$FIX/fake/claude" --resume sid-x $form </dev/null >/dev/null 2>&1 &
  p_sel="$p_sel $!"; sel_forms="$sel_forms|$form"
done
"$FIX/fake/claude" --resume=sid-x </dev/null >/dev/null 2>&1 & p_eqform=$!
"$FIX/fake/claude" --resume "" </dev/null >/dev/null 2>&1 & p_emptysid=$!
# A DIRECTORY named cli.js: node would run its index.js.
DIRCLI="$FIX/dircli/@anthropic-ai/claude-code/cli.js"
mkdir -p "$DIRCLI"; printf '// index\n' > "$DIRCLI/index.js"
"$NODE" "$DIRCLI" --resume sid-x </dev/null >/dev/null 2>&1 & p_dircli=$!
# The exec path's padding, at every length mod 8: a stand-in claude in
# directories whose paths are 8 consecutive lengths long.
p_pad=""; pad_paths=""
for k in 1 2 3 4 5 6 7 8; do
  pd="$FIX/pad$(printf '%*s' "$k" '' | tr ' ' p)/claude"
  need_fake_claude "$pd"
  "$pd" --resume "sid-pad-$k" </dev/null >/dev/null 2>&1 &
  p_pad="$p_pad $!"; pad_paths="$pad_paths $pd"
done
"$FIX/fake/claude" --resume sid-x --fork-session </dev/null >/dev/null 2>&1 & p_fork=$!
"$FIX/fake/claude" "words --resume sid-x" </dev/null >/dev/null 2>&1 & p_oneword=$!
python3 -c 'import time; time.sleep(120)' --resume sid-x </dev/null >/dev/null 2>&1 & p_python=$!
/bin/sh -c 'exec -a "claude --resume sid-x" /bin/sleep 120' </dev/null >/dev/null 2>&1 & p_execa=$!
/bin/sh -c 'exec -a claude /bin/sleep 120 --resume sid-x' </dev/null >/dev/null 2>&1 & p_execa2=$!
p_realnode=""
if command -v node >/dev/null 2>&1; then
  node -e 'setTimeout(()=>{},120000)' -- /fixture/@anthropic-ai/claude-code/cli.js --resume sid-x </dev/null >/dev/null 2>&1 & p_realnode=$!
fi
sleep 1
echo "argv identity: the real image and real argv, never the ps text"
check "positive: an executable named claude, --resume <sid> as two elements" "0" "$(argv_ok "$p_native" sid-x)"
check "positive: Claude Code's versions/<version> image, --session-id <sid>" "0" "$(argv_ok "$p_versions" sid-x)"
check "positive: node whose entry script (argv[1]) is Claude Code's cli.js" "0" "$(argv_ok "$p_node" sid-x)"
check "positive: …reached through the npm bin symlink" "0" "$(argv_ok "$p_nodebin" sid-x)"
check "negative: a launcher-shaped symlink to another script (realpath present)" "1" "$(argv_ok "$p_node_look" sid-x)"
check "negative: a DIRECTORY named …/claude-code/cli.js (node runs its index.js)" "1" "$(argv_ok "$p_dircli" sid-x)"
check "negative: an EMPTY argv[0] (node runs other.js; a shifted parse would see cli.js)" "1" "$(argv_ok "$p_argv0e" sid-x)"
check "…and its identity read gives no answer at all" "1" "$( ( . "$LIBALL" 2>/dev/null; proc_identity "$p_argv0e" >/dev/null; echo $? ) )"
check "…control: the same command with argv[0]=node reads as other.js, rejected" "1" "$(argv_ok "$p_argv0n" sid-x)"
check "…control: …and its identity IS read, entry other.js" "$FIX/other.js" \
  "$( ( . "$LIBALL" 2>/dev/null; proc_identity "$p_argv0n" | tr '\0' '\n' | sed -n 3p ) )"
if [ -n "$p_realargv0" ]; then
  check "negative: the reviewers' repro, a real node with an empty argv[0]" "1" "$(argv_ok "$p_realargv0" sid-x)"
fi
check "negative: --resume <sid> after -- (it is prompt text)" "1" "$(argv_ok "$p_dd_prompt" sid-x)"
check "negative: --resume <sid> --resume <other>" "1" "$(argv_ok "$p_two" sid-x)"
check "negative: --session-id <sid> --resume <other>" "1" "$(argv_ok "$p_two_mixed" sid-x)"
check "positive: --resume <sid>, then -- and prompt text naming another" "0" "$(argv_ok "$p_after_dd" sid-x)"
k=1
for pp in $p_sel; do
  k=$((k+1)); form=$(printf '%s' "$sel_forms" | cut -d'|' -f"$k")
  check "negative: --resume <sid> together with $form" "1" "$(argv_ok "$pp" sid-x)"
done
check "negative (fail closed): --resume=<sid> alone is not accepted either" "1" "$(argv_ok "$p_eqform" sid-x)"
check "negative: an empty session id matches nothing" "1" "$(argv_ok "$p_native" "")"
check "…not even a client launched with --resume \"\"" "1" "$(argv_ok "$p_emptysid" "")"
pad_ok=""; pad_argv0=""; k=0
for pp in $p_pad; do
  k=$((k+1)); pad_ok="$pad_ok$(argv_ok "$pp" "sid-pad-$k")"
  pad_argv0="$pad_argv0 $( ( . "$LIBALL" 2>/dev/null; proc_identity "$pp" | tr '\0' '\n' | sed -n 2p ) )"
done
check "the exec path's padding is skipped exactly, at all 8 lengths mod 8" "00000000" "$pad_ok"
check "…argv[0] reads back as given at every one" "$pad_paths" "$pad_argv0"
check "negative: …the same with no realpath on PATH (no fallback to the raw text)" "1" \
  "$(argv_ok_path "$FIX/norp" "$p_node_look" sid-x)"
check "negative: a resolver that prints the launcher path but fails" "1" \
  "$(argv_ok_path "$FIX/rpfail" "$p_node_look" sid-x)"
check "negative: …even for the genuine entry: a failed resolution is no evidence" "1" \
  "$(argv_ok_path "$FIX/rpfail" "$p_node" sid-x)"
check "negative: a resolver that prints nothing and fails" "1" \
  "$(argv_ok_path "$FIX/rpfailquiet" "$p_node" sid-x)"
check "…control: the native client needs no resolver, on the same PATH" "0" \
  "$(argv_ok_path "$FIX/norp" "$p_native" sid-x)"
check "…but not for another id" "1" "$(argv_ok "$p_native" sid-y)"
check "negative: node -e … -- cli.js --resume <sid> (cli.js is data)" "1" "$(argv_ok "$p_node_e" sid-x)"
check "negative: node -p … cli.js --resume <sid>" "1" "$(argv_ok "$p_node_p" sid-x)"
check "negative: node --require x cli.js --resume <sid>" "1" "$(argv_ok "$p_node_req" sid-x)"
check "negative: node other.js cli.js --resume <sid>" "1" "$(argv_ok "$p_node_other" sid-x)"
check "negative: ANY node option before the script (node --no-warnings cli.js)" "1" "$(argv_ok "$p_node_flag" sid-x)"
check "negative: node -- cli.js" "1" "$(argv_ok "$p_node_dd" sid-x)"
check "negative: a RELATIVE entry, verified from a directory where it would name cli.js" "1" \
  "$( cd "$FIX/relB" && argv_ok "$p_node_rel" sid-x )"
if [ -n "$p_realnode" ]; then
  check "negative: Codex's probe, a real node -e with cli.js as data" "1" "$(argv_ok "$p_realnode" sid-x)"
else
  printf '  skip Codex'"'"'s real-node probe: node is not installed (the stand-in node covers the shape)\n'
fi
check "negative: a fork of the session" "1" "$(argv_ok "$p_fork" sid-x)"
check "negative: '--resume <sid>' inside ONE argv element" "1" "$(argv_ok "$p_oneword" sid-x)"
check "negative: Codex's probe, a Python sleeper with --resume <sid>" "1" "$(argv_ok "$p_python" sid-x)"
check "negative: exec -a 'claude --resume <sid>' /bin/sleep" "1" "$(argv_ok "$p_execa" sid-x)"
check "negative: exec -a claude /bin/sleep … --resume <sid>" "1" "$(argv_ok "$p_execa2" sid-x)"
check "argv_resume_pids finds exactly the five real clients" \
  "$(printf '%s\n' "$p_native" "$p_versions" "$p_node" "$p_nodebin" "$p_after_dd" | sort | tr '\n' ' ')" \
  "$( ( . "$LIBALL" 2>/dev/null; argv_resume_pids sid-x ) | sort | tr '\n' ' ')"
echo "an identity that cannot be read is no evidence"
check "python3 missing: no evidence, even for a real client" "1" \
  "$( ( . "$LIBALL" 2>/dev/null; PATH=/nonexistent; _claude_argv_session "$p_native" sid-x; echo $? ) )"
check "…and proc_identity says it failed" "1" "$( ( . "$LIBALL" 2>/dev/null; PATH=/nonexistent; proc_identity "$p_native" >/dev/null; echo $? ) )"
check "the kernel refuses the read (pid 1, another user's process)" "1" "$( ( . "$LIBALL" 2>/dev/null; proc_identity 1 >/dev/null; echo $? ) )"
check "a read that prints a matching identity and then FAILS is no evidence" "1" \
  "$( ( . "$LIBALL" 2>/dev/null; proc_identity() { printf '%s\0' "$FIX/fake/claude" claude --resume sid-x; return 1; }
        _claude_argv_session "$p_native" sid-x; echo $? ) )"
check "…control: the same answer from a read that succeeds is accepted" "0" \
  "$( ( . "$LIBALL" 2>/dev/null; proc_identity() { printf '%s\0' "$FIX/fake/claude" claude --resume sid-x; return 0; }
        _claude_argv_session "$p_native" sid-x; echo $? ) )"
kill "$p_execa" 2>/dev/null; wait "$p_execa" 2>/dev/null
check "a process that is gone" "1" "$(argv_ok "$p_execa" sid-x)"
kill "$p_native" "$p_versions" "$p_node" "$p_nodebin" "$p_node_e" "$p_node_p" "$p_node_req" "$p_node_other" "$p_node_flag" "$p_node_dd" "$p_node_rel" "$p_node_look" "$p_argv0e" "$p_argv0n" ${p_realargv0:+"$p_realargv0"} \
  "$p_dd_prompt" "$p_two" "$p_two_mixed" "$p_after_dd" "$p_dircli" $p_pad $p_sel "$p_eqform" "$p_emptysid" \
  "$p_fork" "$p_oneword" "$p_python" "$p_execa2" ${p_realnode:+"$p_realnode"} 2>/dev/null
wait 2>/dev/null

echo "Codex's impostor probe: a Python sleeper's pane is not bound (registries empty)"
reset
rtmux new-session -d -s Impostor "exec python3 -c 'import time; time.sleep(60)' --resume review-impostor-sid"
sleep 0.5
imp=$( ( . "$LIBALL" 2>/dev/null; TMUX_TMPDIR="$TMUX_TMPDIR"; export TMUX_TMPDIR; HOME="$HOME"
         compact_target_bound Impostor review-impostor-sid Impostor; echo " rc=$?" ) )
contains "it is refused as unverifiable" "$imp" "rc=2"
echo "…and end to end, neither impostor gets anything typed"
reset
mk_pane Impostor sid-imp ok 0.5 "--resume sid-imp"
compact_run "$FIX/imp.out" -- Impostor
check "the Python agent with --resume <sid> in its argv gets nothing" "0" "$(nlines "$FIX/recv-Impostor.txt")"
contains "…refused as unverified" "$(cat "$FIX/imp.out")" "✗ Impostor: its pane could not be verified"
reset
printf '{"cwd":"%s"}\n{"customTitle":"Spoof"}\n' "$FIX/work" > "$PROJ/sid-spoof.jsonl"
rtmux new-session -d -s Spoof "exec -a 'claude --resume sid-spoof' /bin/sleep 120"
sleep 0.3
compact_run "$FIX/spoof.out" -- Spoof
contains "an exec -a 'claude --resume <sid>' sleeper is refused" "$(cat "$FIX/spoof.out")" "✗ Spoof: its pane could not be verified"
echo "…while a real Claude client of that id in the pane, unstamped and unregistered, binds it"
reset
MK_CHILD="'$FIX/fake/claude' --resume sid-argv" mk_pane ArgvCl sid-argv ok
compact_run "$FIX/argvcl.out" -- ArgvCl
contains "the native shape: compacted" "$(cat "$FIX/argvcl.out")" "✓ ArgvCl: compacted by /compact"
reset
MK_CHILD="'$NODE' '$CLI' --resume sid-node" mk_pane NodeCl sid-node ok
compact_run "$FIX/nodecl.out" -- NodeCl
contains "the node-wrapper shape: compacted" "$(cat "$FIX/nodecl.out")" "✓ NodeCl: compacted by /compact"
reset
MK_CHILD="'$NODE' -e x -- '$CLI' --resume sid-nodee" mk_pane NodeE sid-nodee ok
compact_run "$FIX/nodee.out" -- NodeE
check "node -e with cli.js as data, in the pane: nothing typed" "0" "$(nlines "$FIX/recv-NodeE.txt")"
contains "…refused as unverified" "$(cat "$FIX/nodee.out")" "✗ NodeE: its pane could not be verified"

# ── cleanup when the put-back fails ──────────────────────────────────────────
echo "a request that is not ours and cannot be put back is kept, and the call fails"
CLR="$FIX/clr.sh"
awk '/^_c_clear_request\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$CL" > "$CLR"
grep -q '^_c_clear_request()' "$CLR" || setup_failed "could not extract _c_clear_request"
clr() { # <setup code> -> "rc outcome | request at the path | files left"
  local d="$FIX/clr"; rm -rf "$d"; mkdir -p "$d"
  printf 'another run, cl-done:other-run\n' > "$d/request.md"
  ( . "$CLR"; _CL_STOP_ROOT="$d"; _h_ctok=(cl-done:ours); _h_name=(Review)
    precompact_request_path() { printf '%s/request.md' "$d"; }
    eval "$1"
    _c_clear_request 0 2>/dev/null; rc=$?
    printf '%s %s | %s | %s' "$rc" "$_C_CLEARED" "$(cat "$d/request.md" 2>/dev/null || echo none)" \
      "$(cat "$d"/request.md.clearing.* 2>/dev/null || echo none)" )
}
check "Codex's probe (no hard links): put back by a no-clobber move instead" \
  "0 not-ours | another run, cl-done:other-run | none" "$(clr 'ln() { return 1; }')"
check "link AND move fail: the backup is retained and the result is non-zero" \
  "1 failed | none | another run, cl-done:other-run" \
  "$(clr 'ln() { return 1; }; mv() { case "$1" in -n) return 1 ;; esac; command mv "$@"; }')"
check "a NEWER request (another token) is established at the path: the backup goes" \
  "0 not-ours | newer, cl-done:newer-run | none" "$(clr 'ln() { printf "newer, cl-done:newer-run\n" > "$2"; return 1; }')"
check "something at the path that is not established as newer: the backup is kept" \
  "1 failed | junk with no token | another run, cl-done:other-run" "$(clr 'ln() { printf "junk with no token\n" > "$2"; return 1; }')"
check "…nor is the SAME token in a different file" \
  "1 failed | changed, cl-done:other-run | another run, cl-done:other-run" \
  "$(clr 'ln() { printf "changed, cl-done:other-run\n" > "$2"; return 1; }')"

# ── interrupted ──────────────────────────────────────────────────────────────
echo "SIGTERM after dispatch removes this run's request, and only that"
for variant in own newer; do
  reset
  mk_agent Interrupted sid-int silent
  env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" CL_HANDOFF_DIR="$FIX/store" CL_HANDOFF_VERIFY=1 \
    CL_COMPACT_TIMEOUT=60 bash "$CL" compact Interrupted > "$FIX/int.out" 2>&1 < /dev/null &
  int_pid=$!
  for (( w=0; w<80; w++ )); do [ -s "$FIX/recv-Interrupted.txt" ] && break; sleep 0.1; done
  check "$variant: the premise: the request was written and typed" "1 1" \
    "$([ -f "$FIX/store/Interrupted.precompact" ] && echo 1 || echo 0) $(nlines "$FIX/recv-Interrupted.txt")"
  # A newer, concurrent run's request for the same session: not ours to delete.
  [ "$variant" = "newer" ] && printf 'a newer request, cl-done:999\n' > "$FIX/store/Interrupted.precompact"
  sleep 1.5
  kill -TERM "$int_pid"; wait "$int_pid"; int_rc=$?
  check "$variant: exits 143" "143" "$int_rc"
  if [ "$variant" = "own" ]; then
    check "own: its request file is removed" "0" "$([ -e "$FIX/store/Interrupted.precompact" ] && echo 1 || echo 0)"
    contains "own: …and it says a typed request cannot be recalled" "$(cat "$FIX/int.out")" "cannot be recalled"
    contains "own: …and that it removed one" "$(cat "$FIX/int.out")" "removed 1 pending pre-compact request(s) of this run"
  else
    check "newer: the newer request is left alone" "a newer request, cl-done:999" "$(cat "$FIX/store/Interrupted.precompact" 2>/dev/null)"
    not_contains "newer: …and it does not claim to have removed one" "$(cat "$FIX/int.out")" "removed 1"
    contains "newer: …it says there was none of its own to remove" "$(cat "$FIX/int.out")" "no pending pre-compact request of this run was left to remove"
    check "newer: no clearing leftovers" "0" "$(ls "$FIX/store" | grep -c clearing)"
  fi
  check "$variant: the session is still running" "1" "$(running Interrupted)"
  check "$variant: nothing more was typed" "1" "$(nlines "$FIX/recv-Interrupted.txt")"
done

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
