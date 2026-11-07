#!/usr/bin/env bash
# compact-resume restart mode — run: tests/test-compact-resume.sh
#
# The mode compacts a session before stopping it and resumes it afterwards, so
# it comes back small with its own memory (docs/restart-modes.md). Every step
# of that is confirmed from the TRANSCRIPT, because cl cannot read a Claude
# pane, and every one of those confirmations has a cheap version that is wrong:
#
#   * "the turn finished" — the request file holds the token, so reading it
#     puts the token in a tool_result; a plain search confirms a turn that has
#     only just begun.
#   * "it compacted" — a turn at ~1M tokens can trigger an AUTO compaction;
#     counted, it passes instantly, or leads to compacting a summary again.
#   * "it is at rest" — the busy signal lingers for minutes, so the kill prompt
#     would fire on every compacted session.
#
# So the simulated agent below writes the transcript the way Claude does, and
# each case drives one of those wrong answers to show cl does not take it.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-compact.XXXXXX")"
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
mkdir -p "$PROJ" "$STATEDIR" "$FIX/work" || setup_failed "fixture HOME"
TMUX_TMPDIR="$FIX/tmux-tmp"; mkdir -p "$TMUX_TMPDIR"
rtmux() { TMUX_TMPDIR="$TMUX_TMPDIR" tmux "$@"; }
trap 'rtmux kill-server >/dev/null 2>&1; rm -rf "$FIX"' EXIT

# ── A SIMULATED CLAUDE ──────────────────────────────────────────────────────
#
# It reads typed lines off its own terminal, the way the real agent does, and
# appends to its transcript the records Claude writes:
#
#   every arrival          a user record carrying the typed line
#   a pointer it follows   assistant tool_use, then a user tool_result holding
#                          the FILE's text (so the token really does sit in a
#                          tool_result), then the assistant's reply
#   a finished turn        the metadata Claude writes after one
#                          (stop_hook_summary, turn_duration, last-prompt, …)
#   /compact               a queue-operation, a compact_boundary, the
#                          Compacted stdout record exactly as Claude Code
#                          writes it (string content, ANSI SGR around the
#                          word), the SessionStart attachment records, then a
#                          metadata batch — so "the last record" is never the
#                          conversation record a check is looking for
#
# AGENT_BUSY=1 gives the agent a child process named caffeinate, which is what
# claude_busy reads as "mid-task": the case where only the transcript can say
# the session is really at rest.
#
# Nothing is passed to it out of band: the token and the handoff path are read
# from the request files the typed pointers name. AGENT_MODE picks the
# behaviour each case needs.
AGENT="$FIX/agent.py"
cat > "$AGENT" <<'PYEOF'
import json, os, re, sys, termios, threading, time, uuid
fd = sys.stdin.fileno()
# AGENT_DROP: the first typed line arrives with its START missing, the fault
# the delivery check exists for.
drop = int(os.environ.get("AGENT_DROP", "0"))
arrivals = 0
trailer = None
mode = os.environ.get("AGENT_MODE", "ok")
tr = os.environ["AGENT_TRANSCRIPT"]
recv = os.environ["AGENT_RECV"]
delay = float(os.environ.get("AGENT_DELAY", "0.5"))
def rec(obj):
    obj.setdefault("uuid", str(uuid.uuid4()))
    with open(tr, "a") as fh:
        fh.write(json.dumps(obj) + "\n")
def note(s):
    with open(recv, "a") as fh:
        fh.write(s + "\n")
def assistant(blocks):
    rec({"type": "assistant", "message": {"role": "assistant", "content": blocks}})
# Exactly the bytes Claude Code records: ESC[2m … ESC[22m around the word.
COMPACTED = "<local-command-stdout>\x1b[2mCompacted (ctrl+o to see full summary)\x1b[22m</local-command-stdout>"
def compacted_output():
    rec({"type": "user", "message": {"role": "user", "content": COMPACTED}})
def after_turn():
    for r in ({"type": "system", "subtype": "stop_hook_summary"},
              {"type": "system", "subtype": "turn_duration", "durationMs": 1200},
              {"type": "last-prompt"}, {"type": "file-history-snapshot", "snapshot": {}}):
        rec(r)
def after_compact():
    rec({"type": "attachment", "attachment": {"type": "hook_success", "hookName": "SessionStart:compact"}})
    rec({"type": "attachment", "attachment": {"type": "hook_additional_context", "hookName": "SessionStart"}})
    for r in ({"type": "file-history-snapshot", "snapshot": {}}, {"type": "last-prompt"},
              {"type": "custom-title"}, {"type": "agent-name"}, {"type": "mode"}, {"type": "permission-mode"}):
        rec(r)
if os.environ.get("AGENT_BUSY") == "1":
    import subprocess
    # argv[0] "caffeinate": what claude_busy looks for among the pane's children.
    subprocess.Popen(["caffeinate", "6061"], executable="/bin/sleep",
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def boundary(trigger, pre, post):
    rec({"type": "system", "subtype": "compact_boundary",
         "compactMetadata": {"trigger": trigger, "preTokens": pre, "postTokens": post}})
def read_line():
    data = b""
    while True:
        c = sys.stdin.buffer.read(1)
        if not c:
            return None
        if c in (b"\r", b"\n"):
            return data.decode("utf-8", "replace")
        data += c
def follow(path):
    # Reading the request: the token lands in a tool_result — a USER record.
    assistant([{"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": path}}])
    with open(path) as fh:
        text = fh.read()
    rec({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": text}]}})
    return text
old = termios.tcgetattr(fd)
new = termios.tcgetattr(fd)
new[3] = new[3] & ~termios.ECHO & ~termios.ICANON
termios.tcsetattr(fd, termios.TCSADRAIN, new)
try:
    while True:
        line = read_line()
        if line is None:
            sys.exit(0)
        if line == "":
            continue
        arrivals += 1
        if arrivals == 1 and drop:
            line = line[drop:]
        note(line)
        rec({"type": "user", "message": {"role": "user", "content": line}})
        pre = re.search(r'pre-compact request in "([^"]+)"$', line)
        ho = re.search(r'handoff request in "([^"]+)"$', line)
        if pre:
            if mode == "silent":
                continue
            text = follow(pre.group(1))
            tok = re.search(r'(cl-done:[A-Za-z0-9-]+)', text).group(1)
            time.sleep(delay)
            if mode == "auto-before":
                # A ~1M-token turn tipping over into an AUTO compaction mid-turn.
                boundary("auto", 990000, 21000)
                rec({"type": "user", "isCompactSummary": True,
                     "message": {"role": "user", "content": "summary of the conversation so far"}})
            if mode == "toolresult-only":
                assistant([{"type": "text", "text": "Read it; doing the workflow now."}])
            elif mode == "text-then-tool":
                # The token in text, but the turn goes on with a tool call.
                assistant([{"type": "text", "text": tok},
                           {"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": "true"}}])
            else:
                assistant([{"type": "text", "text": "Workflow done.\n" + tok}])
            after_turn()
            if mode == "trailing":
                # The token is written, but the file keeps growing for a while
                # (metadata after the turn). /compact must wait until it is still.
                def trail():
                    for _ in range(10):
                        time.sleep(0.3)
                        rec({"type": "system", "subtype": "trailing-note"})
                trailer = threading.Thread(target=trail)
                trailer.start()
        elif ho:
            if mode == "silent":
                continue
            text = follow(ho.group(1))
            path = re.search(r'handoff to "([^"]+)"', text).group(1)
            nonce = re.search(r'(clho:[0-9]+:[0-9]+:[0-9]+:[0-9]+)', text).group(1)
            time.sleep(delay)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path + ".tmp", "w") as fh:
                fh.write("simulated handoff\n\n<!-- cl:%s -->\n" % nonce)
            os.rename(path + ".tmp", path)
            assistant([{"type": "text", "text": "Handoff written."}])
        elif line == "/compact":
            if trailer is not None and trailer.is_alive():
                note("COMPACT-WHILE-WRITING")
            rec({"type": "queue-operation", "operation": "enqueue", "content": "/compact"})
            time.sleep(delay)
            if mode == "auto-after":
                # An auto compaction landing after /compact is typed is NOT the
                # manual one cl asked for, and there is no "Compacted" output.
                boundary("auto", 980000, 20000)
                continue
            if mode == "no-boundary":
                continue
            if mode == "output-only":
                # A version whose boundary this check would not recognise, but
                # which still reports the command's output.
                compacted_output()
                after_compact()
                continue
            boundary("manual", 968000, 22000)
            compacted_output()
            if mode == "busy-reader":
                # Compacted, and straight on to new work: reading a file whose
                # text mentions SessionStart and compact. The last conversation
                # record is that tool_result — the session is NOT at rest.
                assistant([{"type": "tool_use", "id": "t3", "name": "Read", "input": {"file_path": "settings.json"}}])
                rec({"type": "user", "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "t3",
                     "content": '{"hooks":{"SessionStart":[{"matcher":"compact","command":"x"}]}}'}]}})
                after_compact()
                continue
            after_compact()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
PYEOF

mk_agent() { # <name> <sid> <mode> [delay] [chars lost from the first arrival]
  # `exec`, so the pane's root process IS the agent: claude_busy looks at that
  # process's children for caffeinate. AGENT_BUSY comes from the caller's env.
  printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX/work" "$1" > "$PROJ/$2.jsonl"
  rtmux new-session -d -s "$1" -c "$FIX" \
    "AGENT_BUSY='${AGENT_BUSY:-0}' AGENT_MODE='$3' AGENT_DELAY='${4:-0.5}' AGENT_DROP='${5:-0}' AGENT_TRANSCRIPT='$PROJ/$2.jsonl' AGENT_RECV='$FIX/recv-$1.txt' exec python3 '$AGENT'" 2>/dev/null \
    || setup_failed "could not start the agent for $1"
}
reset() { rtmux kill-server >/dev/null 2>&1; pkill -f '^caffeinate 6061$' 2>/dev/null; rm -f "$PROJ"/*.jsonl "$FIX"/recv-*.txt "$STATEDIR/state.json" "$STATEDIR/rotation-log.tsv"; }
stop_run() { # <out-file> [extra env...] -- [stop flags...]
  local out="$1"; shift
  local -a envs=() flags=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  flags=("$@")
  # In a new session with NO controlling terminal: the kill prompt reads
  # /dev/tty, so here it cannot be answered and is declined — the unattended
  # outcome, and never a suite that hangs waiting for a keypress.
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    env -i HOME="$HOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" CL_HANDOFF_DIR="$FIX/store" \
    CL_HANDOFF_TIMEOUT=10 CL_HANDOFF_ATTEMPTS=1 CL_HANDOFF_VERIFY=2 CL_COMPACT_TIMEOUT=20 CL_COMPACT_IDLE_POLL=1 \
    ${envs[@]+"${envs[@]}"} bash "$CL" stop --keep-tabs ${flags[@]+"${flags[@]}"} > "$out" 2>&1 < /dev/null
  echo $? > "$out.rc"
}
log_field() { awk -F'\t' -v c="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==c) k=i; next} NR==2{print $k}' "$STATEDIR/rotation-log.tsv"; }
row_field() { jq -r --arg n "$1" --arg f "$2" '.[] | select(.name == $n) | .[$f] // empty' "$STATEDIR/state.json" 2>/dev/null; }
typed_compact() { grep -c '^/compact$' "$FIX/recv-$1.txt" 2>/dev/null | tr -d ' '; }
nlines() { if [ -f "$1" ]; then grep -c . "$1" | tr -d ' '; else echo 0; fi; }
boundaries() { grep -c '"compact_boundary"' "$PROJ/$1.jsonl" 2>/dev/null | tr -d ' '; }

# ── the happy path, several sessions in one window ──────────────────────────
echo "several sessions compact in parallel, in ONE window"
reset
mk_agent CompA sid-ca ok 2
mk_agent CompB sid-cb ok 2
mk_agent CompC sid-cc ok 2
start=$(date +%s)
stop_run "$FIX/happy.out"
happy_elapsed=$(( $(date +%s) - start ))
happy="$(cat "$FIX/happy.out")"
check "all three were asked to finish up" "3" "$(grep -c 'asked ".*" to finish up before /compact' "$FIX/happy.out")"
last_ask=$(grep -n 'to finish up before /compact' "$FIX/happy.out" | tail -1 | cut -d: -f1)
first_compact=$(grep -n 'typed /compact' "$FIX/happy.out" | head -1 | cut -d: -f1)
check "…every ask goes out before any /compact is typed" "1" \
  "$([ -n "$last_ask" ] && [ -n "$first_compact" ] && [ "$last_ask" -lt "$first_compact" ] && echo 1 || echo 0)"
check "each was typed /compact exactly once" "1 1 1" "$(typed_compact CompA) $(typed_compact CompB) $(typed_compact CompC)"
check "…and each compaction was confirmed" "3" "$(grep -c 'compacted (968000 → 22000 tokens)' "$FIX/happy.out")"
# Each agent takes ~2s for its turn and ~2s to compact: serially that is 12s+.
check "three sessions cost about one window, not three (${happy_elapsed}s)" "1" \
  "$([ "$happy_elapsed" -lt 14 ] && echo 1 || echo 0)"
contains "the pointer names the .precompact file" "$(cat "$FIX/recv-CompA.txt")" "pre-compact request in \"$FIX/store/CompA.precompact\""
# The request file is removed once answered, so its text is read back from the
# tool_result the agent recorded when it followed the pointer.
contains "…whose request asks for the exact token as the last line" \
  "$(cat "$PROJ/sid-ca.jsonl")" "last line is exactly cl-done:"
check "…and the request file is cleared once answered" "0" "$([ -e "$FIX/store/CompA.precompact" ] && echo 1 || echo 0)"
not_contains "no handoff was asked for" "$happy" "handoff request"
check "the sessions are stopped" "0" "$(rtmux list-sessions 2>/dev/null | grep -c '^Comp')"
check "the saved row carries the mode, by name and agent" "compact-resume" "$(row_field CompA mode)"
check "…and the uuid of the boundary that confirmed it" \
  "$(grep '"compact_boundary"' "$PROJ/sid-ca.jsonl" | tail -1 | jq -r .uuid)" "$(row_field CompA compact_boundary)"
check "…and it is resume-only, so no stale handoff can rotate it" "true" "$(row_field CompA resume_only)"
check "the log takes the V2 header" "post_tokens" "$(head -1 "$STATEDIR/rotation-log.tsv" | awk -F'\t' '{print $NF}')"
check "…records the mode asked" "compact-resume" "$(log_field mode)"
check "…the path each session took" "compact-resume,compact-resume,compact-resume" "$(log_field paths)"
check "…why" "ok,ok,ok" "$(log_field reasons)"
check "…and the preTokens/postTokens from the boundary record" "968000,968000,968000 22000,22000,22000" \
  "$(log_field pre_tokens) $(log_field post_tokens)"

echo "a busy-looking session at rest after its compaction is stopped with no prompt"
# End to end, on the transcript tail Claude Code really writes: the Compacted
# stdout with its escape codes, then attachments and metadata. The agent also
# LOOKS busy (a caffeinate child), so only the transcript can clear it — and
# unattended a prompt is declined, which would leave it running.
reset
AGENT_BUSY=1 mk_agent Rest sid-rs ok
sleep 0.5
# The premise: a caffeinate child of the pane's own process, which is what
# claude_busy reads as mid-task (the Reader case below shows the prompt fire).
rest_pane=$(rtmux list-panes -t =Rest -F '#{pane_pid}' 2>/dev/null | head -1)
check "the premise: the pane's process has a caffeinate child" "1" \
  "$(pgrep -P "$rest_pane" -f '^caffeinate 6061$' >/dev/null 2>&1 && echo 1 || echo 0)"
stop_run "$FIX/rest.out"
rest="$(cat "$FIX/rest.out")"
contains "the ESC-styled Compacted output confirms the compaction" "$rest" '✓ "Rest" compacted'
not_contains "no mid-task prompt is shown" "$rest" "looks mid-task"
check "the session is stopped" "0" "$(rtmux list-sessions 2>/dev/null | grep -c '^Rest')"
check "…and the stop succeeds" "0" "$(cat "$FIX/rest.out.rc")"
check "the premise: metadata records follow the Compacted output" "permission-mode" \
  "$(tail -1 "$PROJ/sid-rs.jsonl" | jq -r .type)"

echo "…but one that went on to read a file mentioning SessionStart and compact is not at rest"
reset
AGENT_BUSY=1 mk_agent Reader sid-rd busy-reader
sleep 0.5
stop_run "$FIX/reader.out"
reader="$(cat "$FIX/reader.out")"
contains "the compaction is still confirmed" "$reader" '✓ "Reader" compacted'
check "the premise: a tool_result names SessionStart and compact" "1" \
  "$(grep -c '"tool_result".*SessionStart.*compact' "$PROJ/sid-rd.jsonl" | awk '{print ($1>0)}')"
contains "the mid-task prompt is shown" "$reader" '"Reader" looks mid-task'
check "…declined unattended, so the session is left running" "1" "$(rtmux list-sessions 2>/dev/null | grep -c '^Reader')"
check "…and the stop says so by exiting non-zero" "1" "$(cat "$FIX/reader.out.rc")"
reset

echo "retire_session skips its prompt only on the idle-proven argument"
# The plumbing, on retire_session itself: the busy check is stubbed to say
# "mid-task" and the prompt's answer is "no". Only the argument may skip it.
LIB="$FIX/retire.sh"
awk '/^retire_session\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$CL" > "$LIB"
grep -q '^retire_session()' "$LIB" || setup_failed "could not extract retire_session"
rs() { # <idle-proven> -> the retire_session status
  ( . "$LIB"
    agent_hint() { printf claude; }
    tmux() { case "$1" in has-session) return 0 ;; kill-session) return 0 ;; esac; return 1; }
    session_busy() { return 0; }
    close_iterm_tab() { :; }
    # The prompt reads /dev/tty, which a harness cannot feed; a function named
    # `read` answers "no" in its place (it sets the caller's local `ans`).
    read() { ans=n; return 0; }
    retire_session N sid N 0 claude "$1" 2>/dev/null
    echo $? )
}
check "without proof of rest, a busy-looking session is asked about (and kept)" "1" "$(rs 0)"
check "with it, the prompt is skipped and the session stopped" "0" "$(rs 1)"

echo "the token counts only once the transcript has stopped growing"
reset
mk_agent Trail sid-tl trailing
stop_run "$FIX/trail.out"
check "the premise: the agent did keep writing after its token" "1" \
  "$(grep -c trailing-note "$PROJ/sid-tl.jsonl" | awk '{print ($1>3)}')"
check "/compact was typed once" "1" "$(typed_compact Trail)"
not_contains "…and not while the file was still growing" "$(cat "$FIX/recv-Trail.txt")" "COMPACT-WHILE-WRITING"
contains "…and the compaction is confirmed" "$(cat "$FIX/trail.out")" '"Trail" compacted'

echo "the 'Compacted' output alone also confirms /compact"
reset
mk_agent OutOnly sid-oo output-only
stop_run "$FIX/outonly.out" CL_COMPACT_TIMEOUT=8
check "the premise: no boundary was written" "0" "$(boundaries sid-oo)"
contains "the compaction is confirmed from its output" "$(cat "$FIX/outonly.out")" '✓ "OutOnly" compacted'
check "…and the row says compact-resume" "compact-resume" "$(row_field OutOnly mode)"

echo "a pre-compact ask that arrives with its start missing is typed again"
reset
mk_agent CutPre sid-cp ok 0.5 30
stop_run "$FIX/cutpre.out"
contains "cl sees it did not arrive whole" "$(cat "$FIX/cutpre.out")" 'the pre-compact ask to "CutPre" did not arrive whole — typing it again'
contains "…and the session still compacts" "$(cat "$FIX/cutpre.out")" '✓ "CutPre" compacted'

echo "the mode is written by agent AND name"
# A Claude session and a Codex thread can share a name; the Claude session's
# mode must not land on the Codex row. Driven on mark_row_modes itself, since
# a stop over a same-named pair needs a live Codex thread to plan for.
MRM="$FIX/mrm.sh"
awk '/^mark_row_modes\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$CL" > "$MRM"
grep -q '^mark_row_modes()' "$MRM" || setup_failed "could not extract mark_row_modes"
printf '[{"name":"Twin","sid":"s1","agent":"claude"},{"name":"Twin","sid":"s2","agent":"codex"},{"name":"Other","sid":"s3"}]\n' > "$FIX/mrm.json"
( . "$MRM"; STATE="$FIX/mrm.json"; mark_row_modes "claude"$'\t'"Twin"$'\t'"compact-resume"$'\t'"b-7"$'\n'"claude"$'\t'"Other"$'\t'"fresh"$'\t'"-"$'\n' )
check "the Claude row gets the mode and its boundary" "compact-resume b-7" \
  "$(jq -r '.[] | select(.agent=="claude" and .name=="Twin") | "\(.mode) \(.compact_boundary)"' "$FIX/mrm.json")"
check "…the Codex row of the same name gets nothing" "" \
  "$(jq -r '.[] | select(.agent=="codex") | .mode // empty' "$FIX/mrm.json")"
check "…and a row with no agent field counts as Claude" "fresh" \
  "$(jq -r '.[] | select(.name=="Other") | .mode' "$FIX/mrm.json")"

# ── a boundary BEFORE /compact ──────────────────────────────────────────────
echo "an AUTO compaction during the pre-compact turn skips /compact"
reset
mk_agent AutoPre sid-ap auto-before
stop_run "$FIX/autopre.out"
autopre="$(cat "$FIX/autopre.out")"
contains "cl notices the session compacted on its own" "$autopre" '"AutoPre" compacted on its own before /compact'
check "/compact is never typed" "0" "$(typed_compact AutoPre)"
check "…so it compacted exactly once" "1" "$(boundaries sid-ap)"
check "it is treated as compacted" "compact-resume" "$(row_field AutoPre mode)"
check "…with the reason logged" "boundary-before-compact" "$(log_field reasons)"
check "…and the figures from that boundary" "990000 21000" "$(log_field pre_tokens) $(log_field post_tokens)"

# ── an auto boundary AFTER /compact ─────────────────────────────────────────
echo "an auto boundary after /compact is typed does not confirm it"
reset
mk_agent AutoPost sid-apo auto-after
stop_run "$FIX/autopost.out" CL_COMPACT_TIMEOUT=6
autopost="$(cat "$FIX/autopost.out")"
check "/compact was typed once" "1" "$(typed_compact AutoPost)"
check "the premise: an auto boundary really did land after it" "1" "$(boundaries sid-apo)"
not_contains "…and it is NOT reported as this compaction" "$autopost" '✓ "AutoPost" compacted'
contains "the session resumes as-is when no manual boundary comes" "$autopost" '"AutoPost" did not confirm a compaction'
check "…recorded as resume, not compact-resume" "resume" "$(row_field AutoPost mode)"
check "…with the reason" "no-boundary" "$(log_field reasons)"
not_contains "…and no handoff is asked for (it would queue behind the compaction)" "$autopost" "handoff request"

# ── the token in the wrong place ────────────────────────────────────────────
echo "the token inside a tool_result is not the end of the turn"
reset
mk_agent ToolRes sid-tr toolresult-only
stop_run "$FIX/toolres.out" CL_COMPACT_TIMEOUT=5
toolres="$(cat "$FIX/toolres.out")"
check "the premise: the token IS in the transcript, in a tool_result" "1" \
  "$(grep -c 'cl-done:' "$PROJ/sid-tr.jsonl" | awk '{print ($1>0)}')"
check "/compact is never typed" "0" "$(typed_compact ToolRes)"
contains "no reply in time is reported" "$toolres" 'no cl-done reply from "ToolRes"'
contains "…and it falls back to a handoff" "$toolres" 'asking it for a handoff instead'
contains "…which the session then writes" "$toolres" 'handoff written for "ToolRes"'
check "the stop records the handoff path, with why" "handoff no-token+ok" "$(log_field paths) $(log_field reasons)"

echo "…nor is a token followed by a tool call"
reset
mk_agent TextTool sid-tt text-then-tool
stop_run "$FIX/texttool.out" CL_COMPACT_TIMEOUT=5
check "/compact is never typed" "0" "$(typed_compact TextTool)"
contains "…it falls back to a handoff" "$(cat "$FIX/texttool.out")" 'no cl-done reply from "TextTool"'

echo "no reply at all falls back to a handoff"
reset
mk_agent Silent sid-si silent
mkdir -p "$FIX/store"
stop_run "$FIX/silent.out" CL_COMPACT_TIMEOUT=4 CL_HANDOFF_TIMEOUT=3
silent="$(cat "$FIX/silent.out")"
contains "the fallback is announced" "$silent" 'no cl-done reply from "Silent" within 4s'
contains "…a handoff is asked for" "$silent" 'asked "Silent" for'
contains "…and with none arriving either, it stops and resumes as-is" "$silent" 'no handoff from "Silent"'
check "the row says resume" "resume" "$(row_field Silent mode)"

# ── --no-handoff is the fast stop ───────────────────────────────────────────
echo "--no-handoff skips compaction as well"
reset
mk_agent Fast sid-fa ok
stop_run "$FIX/fast.out" -- --no-handoff
fast="$(cat "$FIX/fast.out")"
not_contains "nothing is compacted" "$fast" "/compact"
check "nothing is typed into the session" "0" "$(nlines "$FIX/recv-Fast.txt")"
check "…it is stopped" "0" "$(rtmux list-sessions 2>/dev/null | grep -c '^Fast')"
check "…and recorded as resume, by flag" "resume flag" "$(row_field Fast mode) $(log_field source)"

echo "--require-handoff forces a handoff"
reset
mk_agent Req sid-rq ok
stop_run "$FIX/req.out" -- --require-handoff
req="$(cat "$FIX/req.out")"
not_contains "nothing is compacted" "$req" "/compact"
contains "a handoff lands" "$req" 'handoff written for "Req"'
check "…and the row says handoff" "handoff" "$(row_field Req mode)"

# ── cl start ────────────────────────────────────────────────────────────────
# A stand-in claude that records its argv. FAIL_ON_PROMPT makes it refuse a
# first prompt — the failure the post-launch has-session poll exists for.
FAKE="$FIX/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/claude" <<'SHEOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >> "${CL_AGENT_REC:-/dev/null}"
printf -- '--\n' >> "${CL_AGENT_REC:-/dev/null}"
if [ -n "${FAIL_ON_PROMPT:-}" ]; then
  for a in "$@"; do case "$a" in *"Carry on"*) exit 1 ;; esac; done
fi
exec sleep 60
SHEOF
chmod +x "$FAKE/claude"
ln -sf "$(command -v jq)" "$FAKE/jq"
ln -sf "$(command -v tmux)" "$FAKE/tmux"
mk_transcript() { # <name> <sid> <last-boundary-uuid>
  { printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX/work" "$1"
    printf '{"type":"system","subtype":"compact_boundary","uuid":"old-b","compactMetadata":{"trigger":"auto"}}\n'
    [ -n "$3" ] && printf '{"type":"system","subtype":"compact_boundary","uuid":"%s","compactMetadata":{"trigger":"manual"}}\n' "$3"
  } > "$PROJ/$2.jsonl"
}
write_row() { # <name> <sid> <mode> <boundary>
  printf '[{"name":"%s","sid":"%s","cwd":"%s","agent":"claude","resume_only":true,"mode":"%s","compact_boundary":"%s"}]\n' \
    "$1" "$2" "$FIX/work" "$3" "$4" > "$STATEDIR/state.json"
}
start_run() { # [env...]
  env -i HOME="$HOME" PATH="$FAKE:/usr/bin:/bin" TMUX_TMPDIR="$TMUX_TMPDIR" CL_HANDOFF_DIR="$FIX/store" \
    CL_AGENT_REC="$FIX/argv.txt" CL_RESUME_CHECK=1 "$@" bash "$CL" start 2>&1
}

echo "cl start resumes a compacted session with its first prompt"
reset; rm -f "$FIX/argv.txt"
mk_transcript Back sid-bk b-1
write_row Back sid-bk compact-resume b-1
mkdir -p "$FIX/store"; printf 'old\n<!-- cl:clho:1:1:1:1 -->\n' > "$FIX/store/Back.md"
out=$(start_run)
sleep 0.5
argv="$(cat "$FIX/argv.txt" 2>/dev/null)"
contains "it is resumed by id" "$argv" "--resume"
contains "…with the built-in first prompt as an argument" "$argv" "Carry on where you left off."
contains "…announced as a resume from compaction" "$out" "prepared Back from its compaction"
check "the session is up" "1" "$(rtmux list-sessions 2>/dev/null | grep -c '^Back')"
check "a handoff in the store is neither rotated from nor consumed" "1" "$([ -f "$FIX/store/Back.md" ] && echo 1 || echo 0)"
not_contains "…and never mentioned as a rotation" "$out" "fresh from its handoff"
rtmux kill-server >/dev/null 2>&1

echo "…the first prompt comes from the file when there is one"
reset; rm -f "$FIX/argv.txt"
mk_transcript Back sid-bk b-1
write_row Back sid-bk compact-resume b-1
printf 'Restarted after compaction. Check your board.\n' > "$STATEDIR/resume-after-compact-prompt.txt"
start_run >/dev/null; sleep 0.5
contains "the configured prompt is passed" "$(cat "$FIX/argv.txt" 2>/dev/null)" "Restarted after compaction. Check your board."
rm -f "$STATEDIR/resume-after-compact-prompt.txt"
rtmux kill-server >/dev/null 2>&1

echo "a failed preflight resumes plainly and never consumes a handoff"
for why in "compacted again since" "transcript gone"; do
  reset; rm -f "$FIX/argv.txt" "$FIX/store/Back.md"; rm -rf "$FIX/store/consumed"
  if [ "$why" = "transcript gone" ]; then
    # discover needs the transcript to find the row's session at all on the
    # bare path, but the tmux path works from the row: the row is enough here.
    write_row Back sid-gone compact-resume b-1
  else
    mk_transcript Back sid-bk b-2
    write_row Back sid-bk compact-resume b-1
  fi
  mkdir -p "$FIX/store"; printf 'stale\n<!-- cl:clho:2:2:2:2 -->\n' > "$FIX/store/Back.md"
  out=$(start_run); sleep 0.5
  argv="$(cat "$FIX/argv.txt" 2>/dev/null)"
  contains "$why: it says it is resuming plainly" "$out" "resuming it plainly"
  contains "…it is still resumed by id" "$argv" "--resume"
  not_contains "…without the first prompt" "$argv" "Carry on"
  check "…the handoff is left exactly where it was" "1" "$([ -f "$FIX/store/Back.md" ] && echo 1 || echo 0)"
  check "…and nothing is consumed" "0" "$(ls "$FIX/store/consumed" 2>/dev/null | grep -c .)"
  not_contains "…and no rotation is started" "$argv" "--name"
  rtmux kill-server >/dev/null 2>&1
done

echo "a resume that does not stay up is relaunched plainly"
reset; rm -f "$FIX/argv.txt"
mk_transcript Flaky sid-fl b-9
write_row Flaky sid-fl compact-resume b-9
mkdir -p "$FIX/store"; printf 'stale\n<!-- cl:clho:3:3:3:3 -->\n' > "$FIX/store/Flaky.md"
out=$(start_run FAIL_ON_PROMPT=1); sleep 0.5
contains "the dead launch is noticed" "$out" '"Flaky" did not stay up when resumed with its first prompt'
check "the agent was launched twice: with the prompt, then without" "2" "$(grep -c '^--resume$' "$FIX/argv.txt" 2>/dev/null)"
check "…and the plain one is running" "1" "$(rtmux list-sessions 2>/dev/null | grep -c '^Flaky')"
check "…with the handoff still untouched" "1" "$([ -f "$FIX/store/Flaky.md" ] && echo 1 || echo 0)"
rtmux kill-server >/dev/null 2>&1

echo "the bare-tab path carries the mode in the tab command"
reset; rm -f "$FIX/argv.txt"
NOTMUX="$FIX/notmux"; mkdir -p "$NOTMUX"; cp "$FAKE/claude" "$NOTMUX/claude"; ln -sf "$(command -v jq)" "$NOTMUX/jq"
mk_transcript Tab sid-tb b-5
write_row Tab sid-tb compact-resume b-5
out=$(env -i HOME="$HOME" PATH="$NOTMUX:/usr/bin:/bin" CL_HANDOFF_DIR="$FIX/store" bash "$CL" start 2>&1)
contains "the tab command names the mode and the boundary" "$out" 'cl "Tab" --restart-mode compact-resume b-5'
# The tab itself: it preflights, then execs the agent with the first prompt.
env -i HOME="$HOME" PATH="$NOTMUX:/usr/bin:/bin" CL_HANDOFF_DIR="$FIX/store" CL_AGENT_REC="$FIX/argv.txt" \
  bash "$CL" Tab --restart-mode compact-resume b-5 >/dev/null 2>&1 &
tabpid=$!; sleep 1; kill "$tabpid" 2>/dev/null; wait "$tabpid" 2>/dev/null
contains "the tab resumes with the first prompt" "$(cat "$FIX/argv.txt" 2>/dev/null)" "Carry on where you left off."
rm -f "$FIX/argv.txt"
env -i HOME="$HOME" PATH="$NOTMUX:/usr/bin:/bin" CL_HANDOFF_DIR="$FIX/store" CL_AGENT_REC="$FIX/argv.txt" \
  bash "$CL" Tab --restart-mode compact-resume b-OTHER >/dev/null 2>&1 &
tabpid=$!; sleep 1; kill "$tabpid" 2>/dev/null; wait "$tabpid" 2>/dev/null
not_contains "…and a mismatched boundary resumes it without one" "$(cat "$FIX/argv.txt" 2>/dev/null)" "Carry on"
contains "…still by id" "$(cat "$FIX/argv.txt" 2>/dev/null)" "--resume"

echo "fresh: stopped with no handoff, started as a new session"
reset; rm -f "$FIX/argv.txt" "$STATEDIR/fresh-history.json"
mk_agent Novo sid-nv ok
jq -n '{sessions:{claude:{Novo:"fresh"}}}' > "$STATEDIR/rotate.json"
stop_run "$FIX/fresh.out"
check "nothing is typed into a fresh session at stop" "0" "$(nlines "$FIX/recv-Novo.txt")"
check "the row says fresh" "fresh" "$(row_field Novo mode)"
rtmux kill-server >/dev/null 2>&1
out=$(start_run); sleep 0.5
argv="$(cat "$FIX/argv.txt" 2>/dev/null)"
contains "start launches a NEW session under the name" "$argv" "--name"
not_contains "…not a resume" "$argv" "--resume"
check "…with no first message at all" "--name Novo --dangerously-skip-permissions --" "$(tr '\n' ' ' < "$FIX/argv.txt" | sed 's/ $//')"
check "…and the old id is kept for recovery" "1" "$(grep -c 'sid-nv' "$STATEDIR/fresh-history.json" 2>/dev/null)"
rm -f "$STATEDIR/rotate.json"
rtmux kill-server >/dev/null 2>&1

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
