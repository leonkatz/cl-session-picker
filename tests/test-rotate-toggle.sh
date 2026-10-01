#!/usr/bin/env bash
# test-rotate-toggle.sh — the rotation policy, its precedence, and the per-stop log.
#
# What this suite is actually protecting:
#
#   * PRECEDENCE. Four layers decide whether a session is asked for a handoff
#     (stop flag, CL_ROTATE, stored setting, default-on). Getting the order wrong
#     is silent: you would believe an experiment ran one way while it ran the
#     other, and the measurement would be worthless rather than obviously broken.
#
#   * THE LOG MUST NOT BLOCK A STOP. This is a measurement feature. If it could
#     refuse a shutdown it would be worse than not existing, so an unwritable log
#     is asserted to leave the stop working.
#
#   * WEEK BOUNDARIES. The report groups by the Monday a week starts on. A first
#     version derived a week number from the day of the year, which split a Mon-Fri
#     run of stops across two buckets — mixing the two arms of the very A/B the
#     report exists to make readable.
set -u

CL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-session"
[ -x "$CL" ] || { printf 'FIXTURE SETUP FAILED: %s not executable\n' "$CL" >&2; exit 2; }
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-rotate.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$2" in *"$3"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; *) fail=$((fail+1)); printf '  FAIL %s\n       wanted [%s] in: %s\n' "$1" "$3" "$2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s\n       did NOT want [%s] in: %s\n' "$1" "$3" "$2" ;; *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }
setup_failed() { printf 'FIXTURE SETUP FAILED: %s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || setup_failed "jq is required by the code under test"

export HOME="$FIX/home"
mkdir -p "$HOME/.claude/projects/p1" "$HOME/.claude/projects/p2" "$FIX/work" "$FIX/bin" || setup_failed mkdir
ROT="$HOME/.config/claude-session/rotate.json"
LOG="$HOME/.config/claude-session/rotation-log.tsv"
STATE="$HOME/.config/claude-session/state.json"
# The exact nine-column header this log shipped with before ctx_all existed.
LEGACY_HEADER=$(printf 'timestamp\tmode\tsource\tsessions\thandoffs\tresume_only\tkept\tctx_total\tctx_median')

# Two discoverable Claude sessions, with transcript usage so context_size has a
# figure to report (the log's whole point is recording it).
SID_A=01aaaaaa-0000-7000-8000-0000000000aa
SID_B=01bbbbbb-0000-7000-8000-0000000000bb
mk_claude() { # sid name last_input_tokens
  printf '{"cwd":"%s"}\n{"customTitle":"%s"}\n' "$FIX/work" "$2" > "$HOME/.claude/projects/p1/$1.jsonl"
  printf '{"message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$3" \
    >> "$HOME/.claude/projects/p1/$1.jsonl"
}
mk_claude "$SID_A" Alpha 120000
mk_claude "$SID_B" Beta   40000
# One discoverable Codex thread, so the n/a cell and the never-asked rule have a
# row to be true of.
export CODEX_HOME="$HOME/.codex"
SID_G=01cccccc-0000-7000-8000-0000000000cc
mkdir -p "$CODEX_HOME/sessions/2026/01/01" || setup_failed mkdir-codex
printf '{"id":"%s","thread_name":"Gamma","updated_at":"2026-01-01T00:00:00Z"}\n' "$SID_G" > "$CODEX_HOME/session_index.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$SID_G" "$FIX/work" \
  > "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$SID_G.jsonl"

# A fake claude that records argv, so nothing in this suite can launch a real agent.
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s"\nexit 0\n' "$FIX/argv.claude" > "$FIX/bin/claude"
chmod +x "$FIX/bin/claude" || setup_failed chmod
# No tmux and no osascript: cl then prints commands rather than opening tabs, which
# keeps every case in this suite to the decision under test.
BASEPATH="$FIX/bin:/usr/bin:/bin"
# CL_HANDOFF_BUDGET=1 throughout: these cases are about WHETHER a handoff is asked
# for, never about waiting for one. On the 300s default each stop would block for
# five minutes and the suite would look hung instead of failing.
cl() { ( cd "$FIX" && env -i HOME="$HOME" CODEX_HOME="$CODEX_HOME" PATH="$BASEPATH" CL_HANDOFF_BUDGET=1 \
         ${CL_ROTATE+CL_ROTATE="$CL_ROTATE"} ${CL_SESSION_NAME+CL_SESSION_NAME="$CL_SESSION_NAME"} \
         bash "$CL" "$@" ) ; }

printf 'the default, and changing it\n'
check "rotation is on with no store at all" "on" "$(cl rotate status | awk '/^default/{print $3}')"
check "…and no store file was created by asking" "0" "$([ -e "$ROT" ] && echo 1 || echo 0)"
cl rotate off >/dev/null
check "rotate off sets the default" "off" "$(cl rotate status | awk '/^default/{print $3}')"
cl rotate on >/dev/null
check "rotate on sets it back" "on" "$(cl rotate status | awk '/^default/{print $3}')"
out=$(cl rotate off)
has "…and says what off means" "$out" "will not ask for handoffs"

printf 'a per-session override beats the default, both ways\n'
cl rotate on Alpha >/dev/null
check "override on, default off" "on" "$(cl rotate status | awk '/Alpha/{print $3}')"
check "…and Beta still follows the default" "off" "$(cl --list 2>/dev/null | awk '$2=="Beta"{print $6}')"
cl rotate on >/dev/null; cl rotate off Alpha >/dev/null
check "override off, default on" "off" "$(cl --list 2>/dev/null | awk '$2=="Alpha"{print $6}')"
check "…Beta follows the default again" "on" "$(cl --list 2>/dev/null | awk '$2=="Beta"{print $6}')"
out=$(cl rotate status)
has "status warns overrides spoil a measurement week" "$out" "ambiguous"
cl rotate clear Alpha >/dev/null
check "clear removes the override" "on" "$(cl --list 2>/dev/null | awk '$2=="Alpha"{print $6}')"
out=$(cl rotate status)
has "…and status says there are none" "$out" "overrides: none"

printf 'a hand-edited store is reported, not obeyed\n'
# The file is user-editable, so a nonsense value must not silently become policy.
printf '{"default":"maybe","sessions":{"claude":{"Alpha":"sometimes"}}}\n' > "$ROT"
out=$(cl rotate status 2>&1)
check "an unreadable default falls back to on" "on" "$(cl rotate status 2>/dev/null | awk '/^default/{print $3}')"
has "…and says so" "$out" "ignoring unreadable default"
# A bad per-session value is reported by `rotate status`, not by a listing: `cl`
# renders one row per session into a chooser and must not emit stray text there.
out=$(cl rotate status 2>&1)
has "…and a per-session value is reported by status" "$out" "ignoring unreadable setting"
check "…with that session falling back to the default" "on" "$(cl --list 2>/dev/null | awk '$2=="Alpha"{print $6}')"
rm -f "$ROT"

printf 'codex is n/a — a thread that cannot write a handoff is not "off"\n'
# Reporting "off" would imply it could be switched on. It cannot: a handoff is a
# Claude session summarising itself.
check "rotate on <name> refuses --codex" "1" "$(cl rotate on --codex Alpha >/dev/null 2>&1; echo $?)"
out=$(cl rotate on --codex Alpha 2>&1)
has "…and says why" "$out" "Claude mechanism"
# A discoverable Codex thread, so the LISTING can be checked too. Without one in
# the fixture the n/a cell was unreachable: a revert matrix removed the guard
# that produces it and nothing failed, because no row ever exercised it.
out=$(cl --list 2>/dev/null)
check "a codex row shows n/a in HANDOFF, not a setting" "—" "$(printf '%s' "$out" | awk '$2=="Gamma"{print $6}')"
check "…and the default does not change that" "—" \
  "$(cl rotate off >/dev/null; cl --list 2>/dev/null | awk '$2=="Gamma"{print $6}')"
cl rotate on >/dev/null
# …and it is never asked for a handoff at a stop, whatever the policy says.
out=$(cl stop --dry-run 2>&1)
hasnt "a codex thread is never asked for a handoff" "$out" 'ask "Gamma"'
has   "…while a claude one still is" "$out" 'ask "Alpha"'

printf 'precedence: flag, then CL_ROTATE, then the stored setting\n'
# Asserted through `cl stop --dry-run`, which reports the decision per session
# without killing anything or waiting on a handoff.
cl rotate off >/dev/null
out=$(cl stop --dry-run 2>&1)
has "stored off is honoured" "$out" "rotation off"
out=$(CL_ROTATE=1 cl stop --dry-run 2>&1)
has "CL_ROTATE=1 overrides stored off" "$out" "rotation on"
out=$(cl stop --dry-run --require-handoff 2>&1)
has "a flag overrides stored off" "$out" "rotation on"
cl rotate on >/dev/null
out=$(CL_ROTATE=0 cl stop --dry-run 2>&1)
has "CL_ROTATE=0 overrides stored on" "$out" "rotation off"
out=$(cl stop --dry-run --no-handoff 2>&1)
has "--no-handoff overrides stored on" "$out" "rotation off"
out=$(CL_ROTATE=1 cl stop --dry-run --no-handoff 2>&1)
has "a flag also outranks CL_ROTATE" "$out" "rotation off"
out=$(CL_ROTATE=banana cl stop --dry-run 2>&1)
has "an unparseable CL_ROTATE is reported" "$out" "ignoring CL_ROTATE"
has "…and the stored value is used instead" "$out" "rotation on"
check "…and it is reported exactly once, not per session" "1" \
  "$(printf '%s' "$out" | grep -c 'ignoring CL_ROTATE')"
# Behaviour right, record wrong is still wrong: an ignored value must not be
# logged as the layer that decided, or the provenance in a measurement week lies.
rm -f "$LOG"
CL_ROTATE=banana cl stop --keep-tabs >/dev/null 2>&1
check "an ignored CL_ROTATE is not recorded as the source" "default" \
  "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
rm -f "$LOG"
CL_ROTATE=0 cl stop --keep-tabs >/dev/null 2>&1
check "…while a valid one is" "env" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
rm -f "$LOG"

printf 'rotation off means the handoff is never REQUESTED\n'
# Half the measurement: the request is itself a model call per session, so an
# "off" week has to skip it, not ask and discard.
cl rotate off >/dev/null
out=$(cl stop --dry-run 2>&1)
hasnt "no handoff is requested when off" "$out" "asked"
cl rotate on >/dev/null
out=$(cl stop --dry-run 2>&1)
has "…and one is when on" "$out" 'would ask "Alpha" to write handoff'

printf 'the log records a stop, including an off one\n'
rm -f "$LOG"
cl rotate off >/dev/null
cl stop --keep-tabs >/dev/null 2>&1
check "a log file is created" "1" "$([ -f "$LOG" ] && echo 1 || echo 0)"
check "…with exactly one header" "1" "$(grep -c '^timestamp' "$LOG")"
check "…and one row for the stop" "1" "$(( $(wc -l < "$LOG") - 1 ))"
check "…recording mode off" "off" "$(awk -F'\t' 'NR==2{print $2}' "$LOG")"
check "…naming the layer that decided" "default" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
check "…counting both sessions" "2" "$(awk -F'\t' 'NR==2{print $4}' "$LOG")"
check "…with no handoffs obtained" "0" "$(awk -F'\t' 'NR==2{print $5}' "$LOG")"
# The context figures are the link between rotation and spend; a log without them
# answers nothing.
# Lower median on an even count, which is a choice rather than a law: with two
# sessions of 120k and 40k either is defensible, so the code picks one and the
# comment says which, instead of being silently arbitrary.
check "…and the median context of the two sessions" "40000" "$(awk -F'\t' 'NR==2{print $9}' "$LOG")"
check "…and their total" "160000" "$(awk -F'\t' 'NR==2{print $8}' "$LOG")"
cl stop --keep-tabs >/dev/null 2>&1
check "a second stop appends rather than replacing" "2" "$(( $(wc -l < "$LOG") - 1 ))"
check "…still one header" "1" "$(grep -c '^timestamp' "$LOG")"

printf 'a mixed stop is recorded as mixed, not as one arm of the experiment\n'
rm -f "$LOG"; cl rotate on >/dev/null; cl rotate off Alpha >/dev/null
cl stop --keep-tabs >/dev/null 2>&1
check "mode is mixed when sessions disagreed" "mixed" "$(awk -F'\t' 'NR==2{print $2}' "$LOG")"
check "…and the source says so too" "mixed" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
cl rotate clear Alpha >/dev/null

printf 'an override is recorded even when it agrees with the default\n'
# The defect this catches: source used to be folded into the MODE comparison, so
# with the default on and one session explicitly on, every effective mode was
# "on" and the row recorded whichever source came first in discovery order. A week
# containing a deliberate override then read as a clean A/B sample.
for who in Alpha Beta; do
  rm -f "$LOG"; cl rotate on >/dev/null; cl rotate on "$who" >/dev/null
  cl stop --keep-tabs >/dev/null 2>&1
  check "same-mode override on $who is still flagged" "mixed" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
  check "…with the mode itself still plain on" "on" "$(awk -F'\t' 'NR==2{print $2}' "$LOG")"
  out=$(cl rotate stats)
  check "…and stats does not call that week clean" "yes" \
    "$(printf '%s' "$out" | awk 'NR==2{print $6}')"
  cl rotate clear "$who" >/dev/null
done
# All sessions overridden to the same value is also not a clean sample.
rm -f "$LOG"; cl rotate on Alpha >/dev/null; cl rotate on Beta >/dev/null
cl stop --keep-tabs >/dev/null 2>&1
check "every session overridden is flagged too" "session" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
check "…and stats flags that week" "yes" "$(cl rotate stats | awk 'NR==2{print $6}')"
cl rotate clear Alpha >/dev/null; cl rotate clear Beta >/dev/null
rm -f "$LOG"

printf 'a week is clean only when the stored policy decided it\n'
# The rule is "anything but default contaminates", and it is asserted on the
# OVERRIDES CELL rather than on the raw source: provenance was already correct in
# the log while the summary still called a flag-driven week clean, which is the
# failure that actually misleads.
for flagcase in "--no-handoff" "--require-handoff"; do
  rm -f "$LOG"; cl rotate on >/dev/null
  cl stop --keep-tabs $flagcase >/dev/null 2>&1
  check "$flagcase records itself as the source" "flag" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
  check "…and stats does NOT call that week clean" "yes" "$(cl rotate stats | awk 'NR==2{print $6}')"
done
# A valid CL_ROTATE is a one-off layer too, and is treated the same way. `cl rotate
# off` is the documented way to set an arm for a week; an exported CL_ROTATE held
# all week would in fact be clean, but nothing can distinguish that from a value
# typed once, so it is marked.
rm -f "$LOG"
CL_ROTATE=0 cl stop --keep-tabs >/dev/null 2>&1
check "a valid CL_ROTATE is recorded as env" "env" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
check "…and marks the week as not clean" "yes" "$(cl rotate stats | awk 'NR==2{print $6}')"
# …and the clean case really is clean, so the flag above is not just "always yes".
rm -f "$LOG"
cl stop --keep-tabs >/dev/null 2>&1
check "the stored policy alone leaves the week clean" "default" "$(awk -F'\t' 'NR==2{print $3}' "$LOG")"
check "…and stats says so" "-" "$(cl rotate stats | awk 'NR==2{print $6}')"
rm -f "$LOG"

printf 'a log from the previous version is migrated, not corrupted\n'
# ctx_all was added after this log first shipped. Appending a ten-column row under
# a nine-column header leaves a file the built-in parser happens to read but whose
# header lies to a human or any other tool.
printf '%s\n' "$LEGACY_HEADER" > "$LOG"
printf '2026-09-21T09:00:00Z\ton\tdefault\t4\t4\t0\t0\t400000\t100000\n' >> "$LOG"
cl rotate on >/dev/null
cl stop --keep-tabs >/dev/null 2>&1
check "the header gains the new column" "ctx_all" "$(head -1 "$LOG" | awk -F'\t' '{print $10}')"
check "…and there is still exactly one header" "1" "$(grep -c '^timestamp' "$LOG")"
check "…the legacy row is kept" "1" "$(grep -c '^2026-09-21' "$LOG")"
# Every row must now agree with the header, or the file is still mislabelled. The
# legacy row has nine fields, which reads as an empty ctx_all — the case stats
# already treats as "distribution unavailable".
check "no row claims more fields than the header" "0" \
  "$(awk -F'\t' 'NR==1{h=NF;next} NF>h{c++} END{print c+0}' "$LOG")"
check "the new row carries its distribution" "2" \
  "$(awk -F'\t' 'NR==3{n=split($10,a,","); print n}' "$LOG")"
out=$(cl rotate stats)
check "the legacy week is still reported, marked approximate" "~100k" \
  "$(printf '%s' "$out" | awk '/^2026-09-21/{print $5}')"
# Migration is idempotent: a second stop must not add another header.
cl stop --keep-tabs >/dev/null 2>&1
check "a second stop does not re-migrate" "1" "$(grep -c '^timestamp' "$LOG")"
# A file that is not ours is left completely alone. Migration matches the EXACT
# headers this tool has written; it used to match any first line beginning
# "timestamp", which silently replaced a foreign header with this schema — data
# loss, and a direct contradiction of the rule the function states. The old test
# only used a first line that did not start with "timestamp" at all, so it proved
# nothing about the dangerous branch.
for foreign in \
  'some other tool wrote this' \
  'timestamp_ms	event	value' \
  'timestamp	something	else' \
  'timestamp_ms	ctx_all_of_them	x' \
  'timestamp	mode	source	sessions	handoffs	resume_only	kept	ctx_total' ; do
  printf '%s\nrow one\nrow two\n' "$foreign" > "$LOG"
  before=$(cat "$LOG")
  cl stop --keep-tabs >/dev/null 2>&1
  check "foreign header kept byte-for-byte: ${foreign%%	*}…" "$foreign" "$(head -1 "$LOG")"
  # …and its existing rows are untouched too, not just its first line.
  check "…with its rows intact" "row one row two" \
    "$(sed -n '2,3p' "$LOG" | tr '\n' ' ' | sed 's/ $//')"
done
rm -f "$LOG"

printf 'a migration that cannot complete says so, and still stops\n'
# Silence here would leave exactly the mixed schema the migration exists to
# prevent, with nothing said about it. Two of the three failure points are
# reachable cleanly; all three share one warning.
#
# (a) the lock cannot be taken — a lock left by a process that is gone is reported
#     rather than broken, which is this project's rule everywhere else too.
printf '%s\n' "$LEGACY_HEADER" > "$LOG"
printf '2026-09-21T09:00:00Z\ton\tdefault\t4\t4\t0\t0\t400000\t100000\n' >> "$LOG"
ln -s '999999999:not-a-real-start-token' "$LOG.lock" 2>/dev/null
out=$(cl stop --keep-tabs 2>&1); rc=$?
rm -f "$LOG.lock"
check "a blocked lock still lets the stop succeed" "0" "$rc"
has "…and names the field the header does not" "$out" "ctx_all"
has "…and says how to fix it" "$out" "replacing the first line"
check "…the legacy header is untouched" "$LEGACY_HEADER" "$(head -1 "$LOG")"
check "…and the row was still recorded" "2" "$(grep -c '^20' "$LOG" | tr -d ' ')"
rm -f "$LOG"

# (b) the temp file is created but the replacement is refused — the arrangement
#     that isolates the `mv` itself.
if command -v chflags >/dev/null 2>&1; then
  printf '%s\n' "$LEGACY_HEADER" > "$LOG"
  printf '2026-09-21T09:00:00Z\ton\tdefault\t4\t4\t0\t0\t400000\t100000\n' >> "$LOG"
  chflags uchg "$LOG" 2>/dev/null
  out=$(cl stop --keep-tabs 2>&1); rc=$?
  chflags nouchg "$LOG" 2>/dev/null
  check "a refused replacement still lets the stop succeed" "0" "$rc"
  has "…and is reported rather than silent" "$out" "could not update the column header"
  check "…leaving the original header intact" "$LEGACY_HEADER" "$(head -1 "$LOG")"
  check "…and no temp file left behind" "0" \
    "$(ls "$HOME/.config/claude-session"/*.mig.* 2>/dev/null | grep -c . | tr -d ' ')"
  # An immutable log also refuses the APPEND, so unlike the lock case above this
  # fixture cannot assert the row was recorded. What it can assert is that the
  # failure is reported rather than swallowed — the property that matters when a
  # stop cannot record itself. (I had claimed this fixture checked the row too;
  # it does not, and saying so here is cheaper than a note that drifts.)
  has "…and the lost row is reported, not swallowed" "$out" "not in the rotation log"
else
  # Reported, not skipped silently: a quiet skip is indistinguishable from a pass.
  printf '  SKIP no chflags here — the refused-replacement path is unexercised on this platform\n'
fi
rm -f "$LOG"
printf 'the file is reclassified under the lock, not just before it\n'
# The reason to re-read after acquiring the lock is that the pre-lock evidence may
# no longer describe the file. Checking only "has it already been migrated?" and
# otherwise proceeding meant a log that became FOREIGN while we waited for the lock
# was replaced anyway — the same data loss exact matching prevents, through the back
# door. A static foreign file cannot reach this branch: the file has to change
# between the two reads.
#
# Staged with a lock held by a LIVE process, so the stop genuinely blocks in
# store_lock while the swap happens.
start_token() { ps -o lstart= -p "${1:-$$}" 2>/dev/null | tr -s ' ' | tr ' ' '_'; }
printf '%s\n' "$LEGACY_HEADER" > "$LOG"
printf '2026-09-21T09:00:00Z\ton\tdefault\t4\t4\t0\t0\t400000\t100000\n' >> "$LOG"
sleep 30 & HOLDER=$!
ln -s "$HOLDER:$(start_token "$HOLDER")" "$LOG.lock" 2>/dev/null \
  || setup_failed "could not plant a live migration lock"
cl stop --keep-tabs >/dev/null 2>&1 &
STOPPER=$!
# It classifies the V1 header, then waits on the lock. Swap the file underneath it.
sleep 2
FOREIGN='timestamp_ms	event	value'
printf '%s\nsomeone elses row\n' "$FOREIGN" > "$LOG"
# Release, so the waiting stop acquires the lock and re-reads.
rm -f "$LOG.lock"; kill "$HOLDER" 2>/dev/null; wait "$STOPPER" 2>/dev/null
check "a file that turned foreign while we waited is not rewritten" "$FOREIGN" "$(head -1 "$LOG")"
check "…and its row survives" "someone elses row" "$(sed -n '2p' "$LOG")"
rm -f "$LOG" "$LOG.lock"

# The third point — the temp file cannot be created at all — shares the same
# warning and is not given its own case: isolating it needs the log's directory
# unwritable, which also stops save_state writing state.json and makes `cl stop`
# fail earlier for an unrelated and correct reason. Testing it that way would
# assert the wrong thing.

printf 'an unwritable log never blocks a stop\n'
# A measurement must not be able to stop you shutting down. This is the one
# failure in the feature whose direction is not negotiable.
rm -f "$LOG"
mkdir -p "$HOME/.config/claude-session" 2>/dev/null
printf 'not a log\n' > "$LOG"; chmod 000 "$LOG" 2>/dev/null
out=$(cl stop --keep-tabs 2>&1); rc=$?
check "the stop still succeeds" "0" "$rc"
has "…and says the stop is missing from the log" "$out" "not in the rotation log"
has "…while still reporting the stop itself" "$out" "state saved"
chmod 644 "$LOG" 2>/dev/null; rm -f "$LOG"

printf 'stats group by the Monday a week starts on\n'
# The regression that matters: a Mon-Fri run must be ONE row. Day-of-year
# arithmetic split it in two, mixing the arms of the comparison.
# ctx_all carries every session's context, so the weekly figure can be a real
# median. The rows below use UNEQUAL stop medians and UNEQUAL session counts on
# purpose: with identical ones a median and an average of per-stop medians give
# the same answer, which is why the first version of this test could not tell
# that the code computed the latter while the header claimed the former.
printf 'timestamp\tmode\tsource\tsessions\thandoffs\tresume_only\tkept\tctx_total\tctx_median\tctx_all\n' > "$LOG"
# Week of Mon 2026-09-28. Sessions across the week: 10k,20k,30k (one stop) and
# 1000k (a single-session stop). Sorted: 10,20,30,1000 -> lower median 20k.
# An average of the two stop medians would be (20k + 1000k)/2 = 510k.
printf '2026-09-28T09:00:00Z\ton\tdefault\t3\t3\t0\t0\t60000\t20000\t10000,20000,30000\n' >> "$LOG"
printf '2026-10-02T09:00:00Z\ton\tdefault\t1\t1\t0\t0\t1000000\t1000000\t1000000\n' >> "$LOG"
# Week of Mon 2026-10-05, two stops either side of the week.
printf '2026-10-05T09:00:00Z\toff\tdefault\t2\t0\t2\t0\t360000\t180000\t180000,180000\n' >> "$LOG"
printf '2026-10-09T09:00:00Z\toff\tdefault\t2\t0\t2\t0\t364000\t182000\t182000,182000\n' >> "$LOG"
printf '2026-10-12T09:00:00Z\tmixed\tsession\t2\t1\t1\t0\t240000\t120000\t120000,120000\n' >> "$LOG"
out=$(cl rotate stats)
check "the Mon-Fri run is one week, not two" "1" "$(printf '%s' "$out" | grep -c '^2026-09-28')"
check "…with both cycles in it" "2" "$(printf '%s' "$out" | awk '/^2026-09-28/{print $3}')"
check "…and all four sessions" "4" "$(printf '%s' "$out" | awk '/^2026-09-28/{print $4}')"
# THE statistic assertion: 20k is the median of the week's sessions; 510k would be
# the average of the per-stop medians. Only one of those is what the header says.
check "the weekly figure is a median of sessions, not a mean of stop medians" "20k" \
  "$(printf '%s' "$out" | awk '/^2026-09-28/{print $5}')"
check "Mon and Fri of the next week group together" "2" "$(printf '%s' "$out" | awk '/^2026-10-05/{print $3}')"
check "…and that week reports its own larger median" "180k" \
  "$(printf '%s' "$out" | awk '/^2026-10-05/{print $5}')"
check "a week with overrides is flagged" "yes" "$(printf '%s' "$out" | awk '/^2026-10-12/{print $6}')"
check "…and a clean week is not" "-" "$(printf '%s' "$out" | awk '/^2026-09-28/{print $6}')"
has "stats refuses to pretend it knows cost" "$out" "not money"
# A row from before ctx_all existed: its distribution is gone, so the week is
# marked approximate rather than silently reconstructed.
printf '2026-10-19T09:00:00Z\ton\tdefault\t4\t4\t0\t0\t400000\t100000\n' >> "$LOG"
out=$(cl rotate stats)
check "a legacy row without ctx_all is marked approximate" "~100k" \
  "$(printf '%s' "$out" | awk '/^2026-10-19/{print $5}')"
has "…and the legend explains the marker" "$out" "~ prefix"
# A log containing junk must not take the report down with it.
printf 'garbage line with no tabs\n' >> "$LOG"
out=$(cl rotate stats 2>&1)
check "a malformed line is skipped, not fatal" "2" "$(printf '%s' "$out" | awk '/^2026-09-28/{print $3}')"

printf 'the listing shows policy and pending state separately\n'
rm -f "$LOG"; cl rotate on >/dev/null
out=$(cl --list 2>/dev/null)
has "there is a HANDOFF column" "$out" "HANDOFF"
# …and a HINT column beside it. These were one unlabelled column, which read as
# if the context-size advice were the setting.
has "…and a separate HINT column" "$out" "HINT"
check "a session with rotation on shows on" "on" "$(printf '%s' "$out" | awk '$2=="Alpha"{print $6}')"
# A complete handoff waiting is STATE, not policy, and shows as a marker beside it.
HR="$HOME/.local/state/claude-session/handoff"
mkdir -p "$HR" 2>/dev/null
printf '# notes\n<!-- cl:manual:2026-10-01T09:00:00Z@%s -->\n' "$SID_A" > "$HR/Alpha.md"
out=$(cl --list 2>/dev/null)
check "a pending handoff is marked on the row" "on↻" "$(printf '%s' "$out" | awk '$2=="Alpha"{print $6}')"
check "…and a session without one is not" "on" "$(printf '%s' "$out" | awk '$2=="Beta"{print $6}')"
cl rotate off Alpha >/dev/null
out=$(cl --list 2>/dev/null)
# off + pending is a real, visible inconsistency: someone wrote a handoff by hand
# for a session that will not be asked for one. The next stop clears it.
check "off with a handoff waiting shows both" "off↻" "$(printf '%s' "$out" | awk '$2=="Alpha"{print $6}')"
rm -f "$HR/Alpha.md"; cl rotate clear Alpha >/dev/null

printf 'asked from inside a session, status answers about THAT session\n'
out=$(CL_SESSION_NAME=Alpha cl rotate status)
has "it leads with this session" "$out" 'this session ("Alpha")'
has "…and still reports the default" "$out" "default: rotation"
out=$(cl rotate status)
hasnt "outside a session it does not invent one" "$out" "this session"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
