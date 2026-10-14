#!/usr/bin/env bash
# iterm-broadcast-probe.sh [N] — does sending the handoff ask to N iTerm tabs
# back-to-back actually deliver, and how long does it take?
#
# Run it yourself: tools/iterm-broadcast-probe.sh 12
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
#
# Two questions the automated suite cannot answer, because it drives tmux panes
# and this is AppleScript:
#
#   1. Does the ask DELIVER? A 427-character single-line prompt typed correctly
#      into the pane and then sat there unsent. The fix sends the text, pauses,
#      then sends CR as its own write. Whether the TUI then SUBMITS is beyond
#      this probe (see below) — what it checks is that the whole prompt and its
#      terminator reach the tab at all.
#
#   2. Does it still deliver TWELVE TIMES IN A ROW? `cl stop` now broadcasts —
#      every session is asked before any is waited for — so the sends go out
#      back-to-back with no waits between them. Each one is a separate
#      `osascript` launch that walks every window, tab and session looking for
#      its tag. That is the one path the broadcast changed the timing of, and
#      the only part of it the suite cannot reach.
#
# ── WHAT IT DOES NOT TOUCH ──────────────────────────────────────────────────
#
# It opens its OWN tabs, tagged with a prefix unique to this process, and reads
# and closes only those. No claude is launched, no session is stopped, no
# handoff file is written, and nothing looks at your real sessions. If it dies
# halfway, the leftovers are tabs running `read`; closing them by hand costs
# nothing.
#
# ── WHAT IT PROVES, AND WHAT IT CANNOT ─────────────────────────────────────
#
# PROVES: every send found its tab at this N (tag matching does not degrade with
# many tabs open), each tab received its OWN prompt complete and untruncated,
# the CR terminator actually arrived, and how long N back-to-back sends take.
# That last one is the broadcast's new question, and the first is what fails if
# `osascript` starts dropping work under load.
#
# CANNOT PROVE THE AGENT SUBMITS. Measured 2026-10-13, this probe's own first
# run: `write text ... newline YES` and the two-step
# `write text ... newline NO` + `write text (ASCII character 13)` deliver
# BYTE-IDENTICAL input to the pty — `TEXT` followed by 0x0d, with no
# bracketed-paste markers even when the receiver enables paste mode. The two
# forms differ only in TIMING: the two-step puts a 0.15s gap between the text
# and the CR.
#
# So the reason a long ask did not submit was never the byte. It was that the
# CR arrived in the same burst as a long wrapped line, before the TUI had
# processed it. Nothing that is not a real Claude TUI can reproduce that — a
# read loop accepts text+CR with or without a pause — which is why the earlier
# note here claiming "write text appends LF (0x0a)" was wrong, and why only a
# real `cl stop` can close the submit question.
#
# Each tab writes its file only after CR arrives, so a file appearing is proof
# of DELIVERY, not of submission. A truncated body means the text was cut; a
# missing file means that send never landed.
set -u

N="${1:-12}"
case "$N" in ''|*[!0-9]*) echo "usage: $0 [number-of-tabs]" >&2; exit 2 ;; esac
[ "$N" -ge 1 ] || { echo "$0: N must be at least 1" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the probe can be pointed at a DOCTORED build to prove it still
# fails when it should. A probe that only ever reports success cannot be
# distinguished from one that cannot tell.
CL="${CL_PROBE_SCRIPT:-$HERE/../bin/claude-session}"
[ -r "$CL" ] || { echo "$0: cannot read $CL" >&2; exit 2; }

osascript -e 'tell application "System Events" to (name of processes) contains "iTerm2"' 2>/dev/null \
  | grep -q true || {
  echo "$0: iTerm does not appear to be running — this probe only means anything inside it" >&2
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clprobe.XXXXXX")"
PREFIX="clprobe-$$"

_CLEANED=0
cleanup() {
  # Once only. Belt and braces beside the trap change above: a second pass would
  # re-scan iTerm and re-report, and "cleaned up 0 probe tab(s)" after a real
  # cleanup reads like a failure.
  [ "$_CLEANED" = "1" ] && return 0
  _CLEANED=1
  # By TAG PREFIX, never by window or position: iTerm's "current window" moves,
  # and closing the wrong session here would kill one of the user's sessions.
  #
  # COLLECT FIRST, THEN CLOSE. Closing a session closes its tab, which mutates
  # the very collection being iterated, so the iterator steps past the next one:
  # a 2-tab run left tab 2 behind, a 3-tab run left tab 2 behind, and ten
  # stranded tabs accumulated across runs before anyone noticed — because the
  # close sat inside a `try` that swallowed the failure in silence.
  #
  # Any surviving receiver is killed first: iTerm can refuse to close a session
  # with a live process, and that refusal is a modal dialog nobody asked for.
  pkill -f "$WORK/recv.sh" >/dev/null 2>&1
  # ONE AT A TIME, RE-RESOLVED EACH PASS. Collecting the sessions first and then
  # closing them does not work either: AppleScript hands back positional
  # SPECIFIERS, not stable handles, so closing one invalidates the references
  # held for the rest — measured, 5 of 10 closed and 5 errored. Finding the
  # first match, closing it, and looking again cannot go stale.
  local pass r closed=0
  for pass in $(seq 1 $(( N + 5 ))); do
    r=$(osascript 2>/dev/null <<OSA
tell application "iTerm"
  repeat with w in windows
    repeat with tb in tabs of w
      repeat with s in sessions of tb
        try
          if (variable named "user.clSession") of s starts with "${PREFIX}" then
            close s
            return "closed"
          end if
        end try
      end repeat
    end repeat
  end repeat
  return "none"
end tell
OSA
)
    [ "$r" = "closed" ] || break
    closed=$((closed+1))
    sleep 0.3
  done
  # Reported, not swallowed. A probe that silently leaves tabs behind is worse
  # than one that says it could not — ten of them accumulated unnoticed.
  r=$(osascript 2>/dev/null <<OSA
tell application "iTerm"
  set n to 0
  repeat with w in windows
    repeat with tb in tabs of w
      repeat with s in sessions of tb
        try
          if (variable named "user.clSession") of s starts with "${PREFIX}" then set n to n + 1
        end try
      end repeat
    end repeat
  end repeat
  return n
end tell
OSA
)
  if [ "${r:-0}" != "0" ]; then
    printf '⚠ %s probe tab(s) would not close — tagged %s-*, close them by hand\n' "$r" "$PREFIX" >&2
  else
    printf 'cleaned up %s probe tab(s).\n' "$closed" >&2
  fi
  rm -rf "$WORK"
}
# ── WHY INT AND TERM DO NOT SHARE THE EXIT TRAP ─────────────────────────────
#
# This was `trap cleanup EXIT INT TERM`. A trap handler that RETURNS does not
# terminate the script: bash resumes where it was interrupted. So Ctrl-C ran
# cleanup — closing the tabs and deleting $WORK — and then carried on polling
# for capture files that no longer existed, attempting sends into tabs that were
# gone, and finally ran cleanup a second time at exit.
#
# Especially wrong for a GUI probe, where Ctrl-C is exactly what an operator
# reaches for when the tabs look wrong. The signal handlers now EXIT, which runs
# the EXIT trap once, through the single cleanup path. (Codex, PR #19 review.)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── the REAL send, lifted verbatim ──────────────────────────────────────────
# Extracted rather than reimplemented: a probe that proves a copy of the send
# works has proved nothing about the one `cl stop` uses.
awk '
  !inf && $0 ~ /^(send_text_iterm|tag_iterm_session|open_iterm_tabs)\(\)/ {
    print; if ($0 ~ /}[[:space:]]*$/) next
    inf = 1; next
  }
  inf { print; if ($0 ~ /^}$/) inf = 0 }
' "$CL" > "$WORK/send.sh"
for fn in send_text_iterm tag_iterm_session open_iterm_tabs; do
  grep -q "^${fn}()" "$WORK/send.sh" || { echo "$0: could not extract ${fn} from $CL" >&2; exit 2; }
done
# The CR fix is the thing under test, so refuse to report on a build without it
# rather than measure the old behaviour and call it a pass.
grep -q 'ASCII character 13' "$WORK/send.sh" || {
  echo "$0: the extracted send does not send CR — this build predates the submit fix" >&2
  exit 2
}
. "$WORK/send.sh"

# ── a receiver per tab ──────────────────────────────────────────────────────
# Tags its own tab exactly as a cl session does, then blocks on one line of
# stdin and records what arrived, with the time it arrived.
cat > "$WORK/recv.sh" <<'RECV'
#!/usr/bin/env bash
TAG="$1"; OUT="$2"
b64=$(printf '%s' "$TAG" | base64 | tr -d '\n')
printf '\033]1337;SetUserVar=clSession=%s\007' "$b64"
printf 'probe %s — waiting for one send, then this tab exits on its own.\n' "$TAG"
python3 -c '
import sys, termios, time, os
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
data = b""
try:
    new = termios.tcgetattr(fd)
    new[3] = new[3] & ~termios.ECHO & ~termios.ICANON
    # AND THE INPUT TRANSLATION, which is the whole ballgame here. By default
    # the tty maps an incoming CR to NL (ICRNL), so a process CANNOT tell a
    # real CR from an LF — which is why a receiver that looked correct reported
    # "LF, not CR" against the known-good build, and reported a clean pass
    # against a deliberately broken one. Clearing ICRNL/INLCR/IGNCR makes the
    # bytes arrive as they were sent, which is the only thing worth measuring.
    new[0] = new[0] & ~termios.ICRNL & ~termios.INLCR & ~termios.IGNCR
    # A DEADLINE, so a tab whose send never came still exits and closes itself
    # instead of waiting for a cleanup that may never run. VMIN 0 / VTIME 10
    # makes each read return after 1s of silence.
    new[6][termios.VMIN] = 0
    new[6][termios.VTIME] = 10
    termios.tcsetattr(fd, termios.TCSADRAIN, new)
    deadline = time.time() + 120
    while True:
        if time.time() > deadline:
            break
        c = sys.stdin.buffer.read(1)
        if not c:
            continue
        # CR AND ONLY CR TERMINATES, because that is what the Claude TUI needs
        # to submit long input. A receiver that also accepted LF would be more
        # permissive than the real consumer, and so could not reproduce the bug
        # this probe exists to detect — verified: with LF accepted, a doctored
        # pre-fix build reported a clean pass.
        if c == b"\r":
            break
        if c == b"\n":
            # Noted, not accepted: an LF where a CR belonged IS the bug, and
            # saying so beats a bare "never arrived".
            with open(os.environ["OUT"] + ".lf", "w") as fh:
                fh.write("1")
            continue
        data += c
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
# Written only once CR arrives, which is what makes a file on disk proof that
# the input was submitted and not merely typed.
with open(os.environ["OUT"], "wb") as fh:
    fh.write(data)
with open(os.environ["OUT"] + ".at", "w") as fh:
    fh.write("%.3f" % time.time())
'
RECV
chmod +x "$WORK/recv.sh"

printf 'opening %s probe tab(s)…\n' "$N"
cmds=()
i=1
while [ "$i" -le "$N" ]; do
  cmds+=("OUT='$WORK/recv-$i.txt' '$WORK/recv.sh' '$PREFIX-$i' '$WORK/recv-$i.txt'")
  i=$((i+1))
done
open_iterm_tabs "${cmds[@]}" || { echo "$0: could not open tabs (automation permission?)" >&2; exit 1; }

# Wait for every tab to have TAGGED ITSELF. Sending before the tag exists is a
# race that would report a delivery failure the broadcast is not responsible
# for — the shell has to start and emit the escape first.
printf 'waiting for tabs to tag themselves…\n'
tagged=0; waited=0
while [ "$waited" -lt 30 ]; do
  tagged=$(osascript 2>/dev/null <<OSA
tell application "iTerm"
  set n to 0
  repeat with w in windows
    repeat with tb in tabs of w
      repeat with s in sessions of tb
        try
          if (variable named "user.clSession") of s starts with "${PREFIX}" then set n to n + 1
        end try
      end repeat
    end repeat
  end repeat
  return n
end tell
OSA
)
  [ "${tagged:-0}" -ge "$N" ] && break
  sleep 1; waited=$((waited+1))
done
if [ "${tagged:-0}" -lt "$N" ]; then
  printf '⚠ only %s of %s tabs tagged themselves after %ss — probing what there is\n' \
    "${tagged:-0}" "$N" "$waited" >&2
fi

# ── the broadcast ───────────────────────────────────────────────────────────
# A prompt of the same SHAPE as the real one: a single line, comfortably past
# the ~343-character point where the unsubmitted-input bug began, with a token
# unique to each tab so a cross-delivery cannot read as a success.
printf '\nsending to %s tab(s), back-to-back, no waits between…\n\n' "$N"
t0=$(python3 -c 'import time; print("%.3f" % time.time())')
i=1; sent=0; failed=0
while [ "$i" -le "$N" ]; do
  token="PROBE-TOKEN-$PREFIX-$i"
  body="Before you stop: write a handoff to \"$WORK/handoff-$i.md\" — write it to a temp file and rename it into place, so a partial file is never visible at that path. The LAST line of the file must be exactly \"<!-- cl:$token -->\" with nothing after it. That line is how the caller tells a finished handoff from one cut off mid-write, so write it last, after everything else you intend to do. Once the rename completes, stop."
  s0=$(python3 -c 'import time; print("%.3f" % time.time())')
  if send_text_iterm "$PREFIX-$i" "$body"; then
    sent=$((sent+1)); verdict=sent
  else
    failed=$((failed+1)); verdict="NO TAB MATCHED"
  fi
  s1=$(python3 -c 'import time; print("%.3f" % time.time())')
  printf '  %2s/%s  %-14s %ss\n' "$i" "$N" "$verdict" \
    "$(python3 -c "print('%.2f' % ($s1 - $s0))")"
  # BYTES, not characters. `${#body}` counts characters and `wc -c` counts
  # bytes, so the em dash in the prompt (3 bytes, 1 character) made every
  # perfect delivery read as TRUNCATED by exactly 2 — a false alarm on the
  # thing this probe exists to measure. Caught on the first real run.
  printf '%s' "$body" | wc -c | tr -d ' ' > "$WORK/len-$i.txt"
  i=$((i+1))
done
t1=$(python3 -c 'import time; print("%.3f" % time.time())')
printf '\n%s send(s) dispatched, %s with no matching tab, in %ss total\n' \
  "$sent" "$failed" "$(python3 -c "print('%.2f' % ($t1 - $t0))")"

# ── did it ARRIVE, and did it SUBMIT? ───────────────────────────────────────
printf '\nwaiting up to 20s for the tabs to report what they received…\n\n'
waited=0
while [ "$waited" -lt 20 ]; do
  got=$(ls -1 "$WORK"/recv-*.txt 2>/dev/null | wc -l | tr -d ' ')
  [ "$got" -ge "$sent" ] && break
  sleep 1; waited=$((waited+1))
done

printf '  %-4s %-9s %-10s %s\n' tab arrived bytes verdict
printf '  %-4s %-9s %-10s %s\n' ---- ------- ----- -------
ok=0; bad=0; missing=0
i=1
while [ "$i" -le "$N" ]; do
  f="$WORK/recv-$i.txt"
  want="$(cat "$WORK/len-$i.txt" 2>/dev/null || echo 0)"
  if [ ! -e "$f" ]; then
    if [ -e "$f.lf" ]; then
      printf '  %-4s %-9s %-10s %s\n' "$i" "no" "-" "LF, NOT CR — typed, never submitted (the #18 bug)"
    else
      printf '  %-4s %-9s %-10s %s\n' "$i" "no" "-" "NEVER ARRIVED — nothing reached the tab"
    fi
    missing=$((missing+1))
  else
    at=$(cat "$f.at" 2>/dev/null || echo 0)
    got=$(wc -c < "$f" | tr -d ' ')
    dt=$(python3 -c "print('%.2fs' % ($at - $t0)) if $at > 0 else print('?')")
    if grep -qF "PROBE-TOKEN-$PREFIX-$i" "$f" 2>/dev/null && [ "$got" = "$want" ]; then
      printf '  %-4s %-9s %-10s %s\n' "$i" "$dt" "$got" "ok — complete, own token"
      ok=$((ok+1))
    elif grep -qF "PROBE-TOKEN-$PREFIX-" "$f" 2>/dev/null \
         && ! grep -qF "PROBE-TOKEN-$PREFIX-$i" "$f" 2>/dev/null; then
      printf '  %-4s %-9s %-10s %s\n' "$i" "$dt" "$got" "CROSS-DELIVERED — another tab's prompt"
      bad=$((bad+1))
    else
      printf '  %-4s %-9s %-10s %s\n' "$i" "$dt" "$got" "TRUNCATED — wanted $want bytes"
      bad=$((bad+1))
    fi
  fi
  i=$((i+1))
done

printf '\n'
if [ "$ok" = "$N" ]; then
  printf '✅ all %s delivered complete, with their own prompt and a CR terminator.\n' "$N"
  printf '   That is the DELIVERY question answered for N=%s: no dropped sends, no\n' "$N"
  printf '   truncation, no cross-talk, at this scale and this timing.\n'
  printf '   It does NOT prove the agent submits — only a real `cl stop` does. See the header.\n'
  rc=0
else
  printf '❌ %s of %s ok — %s never arrived, %s arrived wrong.\n' "$ok" "$N" "$missing" "$bad"
  printf '   A missing one is a dropped send or a tag that never matched; a truncated\n'
  printf '   one is the text being cut. Either way `cl stop` would lose that handoff.\n'
  rc=1
fi
printf '\nraw captures (removed when this exits): %s\n' "$WORK"
exit "$rc"
