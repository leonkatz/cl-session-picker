#!/usr/bin/env bash
# Per-session model memory — run: tests/test-session-model.sh
#
# The property: a model remembered for a session NAME reaches the agent as two
# separate argv elements at every launch path, and a session with no remembered
# model launches byte-for-byte as it did before the feature existed.
#
# Two things here are load-bearing beyond "does it work":
#
#   * The value is spliced into shell command strings (tmux's command argument,
#     cmux --command, and the exec paths), so it is validated on the way in and
#     quoted on the way out. A stored file is user-editable, so reading is
#     validated too — the tests below plant a hostile value by hand.
#   * It is stored in its own file, not in state.json. state.json is a snapshot
#     that `cl start` consumes and deletes, so a preference kept there would be
#     erased by the first stop/start cycle. That is asserted, not assumed.
#
# Proven with fake agent binaries that record their real argv, one element per
# line — never by grepping the command string.
#
# ONE GAP, stated rather than hidden: the `printf %q` quoting at use time has no
# test, and cannot have a meaningful one while validation stands. Every value
# that passes the charset check is already shell-safe, so quoting it is a no-op
# — removing the quoting leaves this suite green. It is kept as the second line
# of defence for the day the charset is widened (a model id with a space, say),
# where it becomes the thing that matters. Widen the charset and this comment
# becomes a bug report.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-model.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || setup_failed "jq is required by the code under test"

export HOME="$FIX/home"; export CODEX_HOME="$HOME/.codex"
MODELS="$HOME/.config/claude-session/models.json"
mkdir -p "$HOME/.claude/projects/p1" "$CODEX_HOME/sessions/2026/01/01" "$FIX/work" "$FIX/bin" \
  || setup_failed mkdir

# One discoverable Claude session named Alpha, one Codex session named T.
printf '{"cwd":"%s"}\n{"customTitle":"Alpha"}\n' "$FIX/work" > "$HOME/.claude/projects/p1/c-alpha.jsonl"
SID=01aaaaaa-0000-7000-8000-0000000000aa
printf '{"id":"%s","thread_name":"T","updated_at":"2026-01-01T00:00:00Z"}\n' "$SID" > "$CODEX_HOME/session_index.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$SID" "$FIX/work" \
  > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$SID.jsonl"

mk_fake() { printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s"\nexit 0\n' "$2" > "$FIX/bin/$1"; chmod +x "$FIX/bin/$1"; }
mk_fake claude "$FIX/argv.claude"
mk_fake codex  "$FIX/argv.codex"
# PATH without tmux, so a launch execs the agent directly and its argv is the
# thing under test rather than a tmux command string.
BASEPATH="$FIX/bin:/usr/bin:/bin"

cl() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="${CLPATH:-$BASEPATH}" \
         ${CLARGS:+CL_CODEX_ARGS="$CLARGS"} bash "$CL" "$@" ) ; }
argv() { paste -sd'|' - < "$1" 2>/dev/null; }

printf 'remembering, listing, forgetting\n'
out=$(cl model); rc=$?
check "an empty store says so, and succeeds" "0" "$rc"
case "$out" in *"no session models remembered"*) pass=$((pass+1)); printf '  ok   %s\n' "…naming how to set one" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…naming how to set one" "$out" ;; esac
cl model Alpha some-model-id >/dev/null
check "a remembered model is stored under its name" "some-model-id" "$(jq -r '.claude.Alpha' "$MODELS")"
cl model --claude "Two Words" other-model >/dev/null
check "…including a name with spaces" "other-model" "$(jq -r '.claude."Two Words"' "$MODELS")"
check "listing shows both" "2" "$(cl model | grep -c 'model')"
check "…with the agent named" "2" "$(cl model | grep -cE '^ +claude')"
cl model Alpha replacement-id >/dev/null
check "setting again replaces rather than appends" "replacement-id" "$(jq -r '.claude.Alpha' "$MODELS")"
check "…and does not disturb the other entry" "other-model" "$(jq -r '.claude."Two Words"' "$MODELS")"
cl model --claude "Two Words" - >/dev/null
check "'-' forgets one" "null" "$(jq -r '.claude."Two Words" // "null"' "$MODELS")"
check "…leaving the rest" "replacement-id" "$(jq -r '.claude.Alpha' "$MODELS")"

printf 'a value that could act as shell syntax is refused\n'
# The stored value ends up inside a command string. These are the shapes that
# would matter if it were not checked.
for bad in 'x; touch pwned' 'x$(id)' 'x`id`' 'x&&y' 'x|y' 'x y' '$HOME' ''; do
  before="$(cat "$MODELS")"
  cl model Alpha "$bad" >/dev/null 2>&1; rc=$?
  check "refused: [$bad]" "1" "$rc"
  check "…store untouched" "same" "$([ "$before" = "$(cat "$MODELS")" ] && echo same || echo CHANGED)"
done
check "…and the good value is still there" "replacement-id" "$(jq -r '.claude.Alpha' "$MODELS")"
check "…no side effect ran" "0" "$(ls "$FIX"/pwned "$FIX"/*/pwned 2>/dev/null | wc -l | tr -d ' ')"

printf 'real model identifiers are accepted\n'
for good in claude-sonnet-4-5 opus gpt-5 vendor.model-name:v1 provider/family:2024-10-01 a_b.c-d:e/f; do
  cl model Alpha "$good" >/dev/null 2>&1
  check "accepted: $good" "$good" "$(jq -r '.claude.Alpha' "$MODELS")"
done

printf 'the model reaches the agent as separate argv elements\n'
rm -f "$FIX/argv.claude"
cl model Alpha no-such-model >/dev/null
cl Alpha >/dev/null 2>&1
check "claude: --model and the id are two elements" "1" \
  "$(grep -c '^--model$' "$FIX/argv.claude")"
check "…with the id immediately after" "no-such-model" \
  "$(grep -A1 '^--model$' "$FIX/argv.claude" | tail -1)"
check "…alongside the flags it always had" "1" \
  "$(grep -c '^--dangerously-skip-permissions$' "$FIX/argv.claude")"

rm -f "$FIX/argv.codex"
cl model T codex-model-id >/dev/null
cl --codex T >/dev/null 2>&1
check "codex: -m and the id are two elements" "-m|codex-model-id" \
  "$(grep -A1 '^-m$' "$FIX/argv.codex" | paste -sd'|' -)"
check "…and the subcommand still follows the options" "resume|$SID" \
  "$(grep -A1 '^resume$' "$FIX/argv.codex" | paste -sd'|' -)"

printf 'a session with no remembered model launches exactly as before\n'
# The regression that would hurt most quietly: a stray flag, or an empty one,
# on every session that never asked for a model.
cl model Alpha - >/dev/null
rm -f "$FIX/argv.claude"
cl Alpha >/dev/null 2>&1
check "claude: no --model appears" "0" "$(grep -c '^--model$' "$FIX/argv.claude")"
check "…and no empty argv element" "0" "$(grep -c '^$' "$FIX/argv.claude")"
check "…the resume grammar is untouched" "--resume|$(jq -r 'empty' /dev/null; echo)" "$(head -1 "$FIX/argv.claude")|"
cl model T - >/dev/null
rm -f "$FIX/argv.codex"
cl --codex T >/dev/null 2>&1
check "codex: no -m appears" "0" "$(grep -c '^-m$' "$FIX/argv.codex")"
check "…argv is exactly resume <id>" "resume|$SID" "$(argv "$FIX/argv.codex")"

printf 'an explicit CL_CODEX_ARGS model wins over the remembered one\n'
# CL_CODEX_ARGS is documented as trusted verbatim shell syntax the user
# controls. Two model flags would either conflict or silently pick one.
cl model T remembered-model >/dev/null
rm -f "$FIX/argv.codex"
CLARGS='-m explicit-model' cl --codex T >/dev/null 2>&1
check "only one model flag is passed" "1" "$(grep -c '^-m$' "$FIX/argv.codex")"
check "…and it is the explicit one" "explicit-model" "$(grep -A1 '^-m$' "$FIX/argv.codex" | tail -1)"
rm -f "$FIX/argv.codex"
CLARGS='--model explicit-long' cl --codex T >/dev/null 2>&1
check "the long form is recognised too" "0" "$(grep -c '^-m$' "$FIX/argv.codex")"
cl model T - >/dev/null

printf 'a hand-edited store cannot smuggle a value onto a command line\n'
# models.json is a plain file in the user's config dir. Validating only on the
# way in would leave the read path trusting whatever is on disk.
mkdir -p "$(dirname "$MODELS")"
printf '{"claude": {"Alpha": "evil; touch %s/pwned-read"}}\n' "$FIX" > "$MODELS"
rm -f "$FIX/argv.claude"
out=$(cl Alpha 2>&1 >/dev/null)
check "the unsafe stored value is not used" "0" "$(grep -c '^--model$' "$FIX/argv.claude")"
check "…nothing executed" "0" "$([ -e "$FIX/pwned-read" ] && echo 1 || echo 0)"
case "$out" in *"unsafe model"*) pass=$((pass+1)); printf '  ok   %s\n' "…and it says why" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and it says why" "$out" ;; esac
printf '{}\n' > "$MODELS"

printf 'the memory survives a stop/start cycle\n'
# state.json is a snapshot that `cl start` consumes and DELETES. A model kept
# there would be gone after one cycle — this is why it lives in its own file.
cl model Alpha persistent-model >/dev/null
STATE="$HOME/.config/claude-session/state.json"
printf '[{"name":"Alpha","sid":"abc","cwd":"%s","agent":"claude"}]\n' "$FIX/work" > "$STATE"
cl start >/dev/null 2>&1
check "state.json was consumed by start" "0" "$([ -f "$STATE" ] && echo 1 || echo 0)"
check "…but the remembered model is still there" "persistent-model" "$(jq -r '.claude.Alpha' "$MODELS")"

printf 'cl new --model remembers and applies in one step\n'
# Without a TTY `cl new` deliberately refuses to exec an agent, so this path
# launches through tmux. A fake tmux records the command STRING it is handed —
# which is what tmux itself will re-split, so the string is the real interface
# here, not argv.
mkdir -p "$FIX/tmuxbin"
# One line per invocation, appended: cl calls tmux several times (has-session
# probes, setup) and a fake that overwrites records only the last one — which
# is not the launch.
# `has-session` must report NOT-found, or cl correctly refuses to create a
# session it believes already exists — and the fake would be testing its own
# wrong answer rather than the launch.
cat > "$FIX/tmuxbin/tmux" <<TMUXEOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$FIX/argv.tmux"
case "\$1" in has-session) exit 1 ;; esac
exit 0
TMUXEOF
chmod +x "$FIX/tmuxbin/tmux"
cl_tmux() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$FIX/tmuxbin:$BASEPATH" bash "$CL" "$@" ) ; }
rm -f "$FIX/argv.tmux"
cl_tmux new --model new-session-model "Fresh" "$FIX/work" >/dev/null 2>&1
check "it is remembered for the name" "new-session-model" "$(jq -r '.claude.Fresh' "$MODELS")"
TCMD="$(grep 'new-session' "$FIX/argv.tmux" 2>/dev/null | tail -1)"
case "$TCMD" in *"--model new-session-model"*) pass=$((pass+1)); printf '  ok   %s\n' "…and used for the launch" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and used for the launch" "$TCMD" ;; esac
case "$TCMD" in *"--name Fresh"*) pass=$((pass+1)); printf '  ok   %s\n' "…without losing the name flag" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…without losing the name flag" "$TCMD" ;; esac
out=$(cl new --model 'bad; id' "Fresh2" "$FIX/work" 2>&1 >/dev/null); rc=$?
check "an unsafe --model refuses the whole launch" "1" "$rc"
check "…and remembers nothing" "null" "$(jq -r '.claude.Fresh2 // "null"' "$MODELS")"

printf 'the same name under two agents keeps two separate models\n'
# The reason the store is keyed by agent AND name. A Claude session and a Codex
# session can both be called Alpha; `cl --claude Alpha` resolves that ambiguity
# for the LAUNCH, and a name-only store would still have handed it the other
# agent's model — `claude --model <a-codex-model>`.
printf '{"id":"%s","thread_name":"Alpha","updated_at":"2026-01-02T00:00:00Z"}\n' \
  01cccccc-0000-7000-8000-0000000000cc >> "$CODEX_HOME/session_index.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' \
  01cccccc-0000-7000-8000-0000000000cc "$FIX/work" \
  > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-02T00-00-00-01cccccc-0000-7000-8000-0000000000cc.jsonl"
cl model --claude Alpha claude-side-model >/dev/null
cl model --codex  Alpha codex-side-model  >/dev/null
check "each agent stores its own" "claude-side-model|codex-side-model" \
  "$(jq -r '"\(.claude.Alpha)|\(.codex.Alpha)"' "$MODELS")"
rm -f "$FIX/argv.claude" "$FIX/argv.codex"
cl --claude Alpha >/dev/null 2>&1
check "the claude launch gets the claude model" "claude-side-model" \
  "$(grep -A1 '^--model$' "$FIX/argv.claude" | tail -1)"
cl --codex Alpha >/dev/null 2>&1
check "the codex launch gets the codex model" "codex-side-model" \
  "$(grep -A1 '^-m$' "$FIX/argv.codex" | tail -1)"

printf 'a bare name that two agents share is refused, not guessed\n'
out=$(cl model Alpha whatever 2>&1); rc=$?
check "…exits non-zero" "1" "$rc"
case "$out" in *"more than one agent"*) pass=$((pass+1)); printf '  ok   %s\n' "…naming both ways to disambiguate" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…naming both ways to disambiguate" "$out" ;; esac
check "…and nothing was written" "claude-side-model" "$(jq -r '.claude.Alpha' "$MODELS")"
cl model --claude Alpha - >/dev/null; cl model --codex Alpha - >/dev/null

printf 'a trailing --model fails with usage instead of hanging\n'
# `shift 2 || true` with one argument left leaves the arguments untouched, so
# the parser loop sees the same flag forever. It hung until it was killed.
for args in "--model" "--codex --model" "--claude --model"; do
  ( cl new $args >"$FIX/hang.out" 2>&1 & P=$!
    ( sleep 5; kill -9 $P 2>/dev/null ) 2>/dev/null &
    W=$!; wait $P 2>/dev/null; rc=$?; kill $W 2>/dev/null; echo "$rc" > "$FIX/hang.rc" ) 2>/dev/null
  rc="$(cat "$FIX/hang.rc")"
  check "cl new $args exits rather than looping" "1" "$rc"
  case "$(cat "$FIX/hang.out")" in *usage:*) pass=$((pass+1)); printf '  ok   %s\n' "…with a usage message" ;;
    *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…with a usage message" "$(cat "$FIX/hang.out")" ;; esac
done

printf 'every form of an explicit Codex model wins\n'
# Codex parses with clap: -m V, -mV, --model V and --model=V are all valid.
# Recognising only the spaced forms let two model options reach codex.
cl model --codex T remembered-model >/dev/null
for explicit in '-m explicit1' '--model explicit2' '--model=explicit3' '-mexplicit4'; do
  rm -f "$FIX/argv.codex"
  CLARGS="$explicit" cl --codex T >/dev/null 2>&1
  check "[$explicit] leaves the remembered model out" "0" \
    "$(grep -c '^remembered-model$' "$FIX/argv.codex")"
done
cl model --codex T - >/dev/null

printf 'two writers do not lose each other\n'
# An atomic rename keeps the file whole; it does not stop two shells reading the
# same object and the later rename dropping the earlier edit.
printf '{}\n' > "$MODELS"
( cl model --claude WriterA model-a >/dev/null 2>&1 ) &
( cl model --claude WriterB model-b >/dev/null 2>&1 ) &
wait
check "both entries survive" "model-a|model-b" \
  "$(jq -r '"\(.claude.WriterA)|\(.claude.WriterB)"' "$MODELS")"
check "…and no lock is left behind" "0" \
  "$([ -L "$MODELS.lock" ] && echo 1 || echo 0)"

# The above depends on two writers actually overlapping, which is timing. The
# lock's contract is checked directly and deterministically here: a live holder
# is waited for, a dead one is reclaimed — never the other way round, which is
# how a lock either corrupts or wedges.
printf 'the lock waits for a live holder and reclaims a dead one\n'
MYTOK="$$:$(ps -o lstart= -p $$ 2>/dev/null | tr -s ' ' | tr ' ' '_')"
ln -s "$MYTOK" "$MODELS.lock"
out=$(cl model --claude Blocked nope 2>&1); rc=$?
check "a live holder is not displaced" "1" "$rc"
check "…its lock is byte-identical afterwards" "$MYTOK" "$(readlink "$MODELS.lock")"
check "…and nothing was written" "null" "$(jq -r '.claude.Blocked // "null"' "$MODELS")"
case "$out" in *"another process is updating"*) pass=$((pass+1)); printf '  ok   %s\n' "…and it says so" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…and it says so" "$out" ;; esac
rm -f "$MODELS.lock"
# A dead holder's lock is REPORTED, never reclaimed automatically. Validating a
# symlink and then removing its pathname are two operations, and between them
# another waiter can acquire — that delete would then destroy a live claim and
# put two writers inside the transaction. Same rule, same reason, as the launch
# lock. Two concurrent reclaimers cannot race when nobody reclaims.
ln -s "999999:Mon_Jan__1_00:00:00_2001" "$MODELS.lock"
out=$(cl model --claude Reclaimed yes 2>&1); rc=$?
check "a dead holder's lock is NOT silently reclaimed" "1" "$rc"
check "…and nothing was written" "null" "$(jq -r '.claude.Reclaimed // "null"' "$MODELS")"
check "…the lock is left for a person to clear" "1" "$([ -L "$MODELS.lock" ] && echo 1 || echo 0)"
case "$out" in *"rm -f"*) pass=$((pass+1)); printf '  ok   %s\n' "…with the exact command to clear it" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "…with the exact command to clear it" "$out" ;; esac
rm -f "$MODELS.lock"
# …and once cleared by hand, the write goes through.
cl model --claude Reclaimed yes >/dev/null 2>&1
check "after clearing it by hand, the write succeeds" "yes" "$(jq -r '.claude.Reclaimed // "null"' "$MODELS")"

# Fail closed on our own identity: a lock created from an empty token publishes
# a weak "PID:" holder that the next writer would read as stale.
mkdir -p "$FIX/noident"
printf '#!/bin/sh\nexit 1\n' > "$FIX/noident/ps"; chmod +x "$FIX/noident/ps"
before="$(cat "$MODELS")"
out=$(CLPATH="$FIX/noident:$BASEPATH" cl model --claude Unowned x 2>&1); rc=$?
check "a writer that cannot identify itself does not take the lock" "1" "$rc"
check "…and writes nothing" "same" "$([ "$before" = "$(cat "$MODELS")" ] && echo same || echo CHANGED)"
check "…leaving no lock behind" "0" "$([ -L "$MODELS.lock" ] && echo 1 || echo 0)"

printf 'a create that cannot proceed leaves no preference behind\n'
# `cl new --model X "Name" /missing` used to store X and then fail — a half-done
# transaction presented as one step.
printf '{}\n' > "$MODELS"
out=$(cl new --model stored-too-early "Ghost" "$FIX/no-such-dir" 2>&1); rc=$?
check "the create fails" "1" "$rc"
check "…and nothing was remembered for it" "null" "$(jq -r '.claude.Ghost // "null"' "$MODELS")"
out=$(cl new --model also-too-early "Ghost2" -d 2>&1); rc=$?
check "an unset CL_DEFAULT_DIR fails too" "1" "$rc"
check "…remembering nothing" "null" "$(jq -r '.claude.Ghost2 // "null"' "$MODELS")"

printf 'a create that the backend refuses remembers nothing\n'
# The earlier tests covered validation failures (missing directory, unset
# default). These are the ones that get past validation and are refused by the
# backend — where the model was still being stored because the write happened
# before the hand-off, not after acceptance.
printf '{}\n' > "$MODELS"
mkdir -p "$FIX/tmuxbin2"
# A tmux that reports the session ALREADY EXISTS: `new-session -A` would have
# attached it, and attaching is not creating.
cat > "$FIX/tmuxbin2/tmux" <<TMUX2
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/tmux2.calls"
case "\$1" in has-session) exit 0 ;; esac
exit 0
TMUX2
chmod +x "$FIX/tmuxbin2/tmux"
rm -f "$FIX/tmux2.calls"
CLPATH="$FIX/tmuxbin2:$BASEPATH" cl new --model attached-not-created "Existing" "$FIX/work" >/dev/null 2>&1
check "attaching an existing session stores nothing" "null" \
  "$(jq -r '.claude.Existing // "null"' "$MODELS")"
check "…creating nothing new" "0" \
  "$(grep -c 'new-session' "$FIX/tmux2.calls" 2>/dev/null)"
# Without a TTY this is the DETACHED branch, which reports "already exists"
# rather than attaching. The interactive branch (launch_named) attaches instead,
# and is the one `new-session -A` used to hide; it cannot be exercised here
# because it needs a terminal, so its guard is asserted by the tmux call
# pattern above rather than end to end.

# And when the session does NOT exist, it is created and the model is stored.
cat > "$FIX/tmuxbin2/tmux" <<TMUX3
#!/bin/sh
printf '%s\n' "\$*" >> "$FIX/tmux2.calls"
case "\$1" in has-session) exit 1 ;; esac
exit 0
TMUX3
rm -f "$FIX/tmux2.calls"
CLPATH="$FIX/tmuxbin2:$BASEPATH" cl new --model really-created "Fresh3" "$FIX/work" >/dev/null 2>&1
check "a real creation stores the model" "really-created" "$(jq -r '.claude.Fresh3 // "null"' "$MODELS")"
check "…having actually created a session" "1" \
  "$(grep -c 'new-session' "$FIX/tmux2.calls" 2>/dev/null)"

# The backend ACCEPTING is the condition, not the backend being reached. A
# new-session that fails must leave no preference behind — this is the case
# that distinguishes "write then create" from "create then write".
cat > "$FIX/tmuxbin2/tmux" <<TMUX4
#!/bin/sh
printf '%s
' "\$*" >> "$FIX/tmux2.calls"
case "\$1" in has-session) exit 1 ;; new-session) exit 1 ;; esac
exit 0
TMUX4
rm -f "$FIX/tmux2.calls"
CLPATH="$FIX/tmuxbin2:$BASEPATH" cl new --model create-failed "Doomed" "$FIX/work" >/dev/null 2>&1
check "a failed create stores nothing" "null" "$(jq -r '.claude.Doomed // "null"' "$MODELS")"
check "…having tried" "1" "$(grep -c 'new-session' "$FIX/tmux2.calls" 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
