# Handoff and fresh start

## Why

`cl start` resumes a named session by id, and the agent reloads the whole
transcript on every call. A long-lived working session accumulates context
that is re-sent forever, whether or not any of it still matters.

Measured across a set of long-running sessions, the spread looked like this:

| session age / use | approximate context |
|---|---|
| oldest, in daily use for weeks | ~900k |
| several weeks old | ~700–800k |
| a few weeks old | ~350–600k |
| fresh | ~40–60k |

The oldest sessions were paying something like 6–15× per call for history that
had long since stopped being read. `cl` had no way to retire that history
without losing what makes a session findable — its name, its directory, its
wrapper choice, and cross-session reachability — and no way to notice a session
had become expensive without opening it.

## Design

The handoff is the **hinge between two runs**: `cl stop` writes it, and the
next `cl start` rotates off it. One invariant carries the whole design:

> **At most one unconsumed handoff per session.**

So the mere presence of `<store>/<Name>.md` means "written, and not yet used" —
there is no mtime comparison, no staleness heuristic, and no second source of
truth to drift from the files. Whatever uses a handoff moves it to
`<store>/consumed/`; whatever is about to request one sweeps a leftover first.

### 1. Handoff on `cl stop`

Before a live session is killed, `cl stop` asks it — in its own pane — to write
a handoff, then waits for the file.

The session writes the handoff, not `cl`: the session has the context and `cl`
never does. The mechanism is to **type an instruction into the pane**, the same
trust boundary `cl` already crosses for `close_iterm_tab` and
`open_iterm_tabs`: one literal, single-line instruction sent as if a person had
typed it, then Enter. It works under tmux (`send-keys -l`), a tagged iTerm tab
(`write text`), and cmux (`send` plus a separate `send-key enter`).

`cl` never reads the pane back. The agent's TUI runs on the alternate screen
buffer, so `capture-pane` cannot see it — the same reason `session_busy`
inspects the process tree instead. The handoff **file** is the one externally
observable outcome, so that is what gets polled.

Completion is confirmed by a **per-request nonce**, not by mtime or a content
hash. A hash cannot tell a fresh handoff from a byte-identical one left by an
earlier rotation, and an unrelated write or a sync reconciling mid-flight moves
an mtime without this request's handoff having landed at all. The instruction
asks for a token to be written verbatim into the file; `cl` waits for that
exact token.

The request is made up to `CL_HANDOFF_ATTEMPTS` times (default 3) with a fresh
nonce each round, because a session mid-task may not read the first one.

**A session whose handoff never lands is left running.** It is not killed. The
reasoning: `cl start` decides how a session comes back by whether a handoff is
there, so stopping one without a handoff silently turns a rotation into a plain
resume. Leaving it alive costs a tab and keeps both options open. The two ways
forward are printed rather than implied — write the handoff by hand from inside
the session (§3), or `cl stop --no-handoff` to stop it deliberately.

An unreachable pane fails on the first attempt rather than burning the rest:
retrying cannot fix "there is nothing to type into".

### 2. Rotation on `cl start`

`cl start` brings back everything in the last snapshot. Per session, the
presence of an unconsumed handoff decides how:

| | |
|---|---|
| **handoff present** | consume it, start a **new** agent under the **same name**, in the same directory, through the same wrapper selection, and hand it the file as its first message |
| **no handoff** | `--resume <sid>`, exactly as before |

That second row is what makes every failure above safe. A skipped handoff, an
unreachable session, a crash — all of them simply leave no file, and the
session comes back whole. **Rotation is the optimisation; resuming is the
floor.** Nothing in this feature can cost you a session.

Because the name, directory and reachability survive, `cl "Name"` and
cross-session messaging keep resolving to the current occupant of that name.

**The old session is never a dead end.** The previous session id is appended to
`~/.config/claude-session/fresh-history.json` with the name, directory and
timestamp, and the direct recovery command is printed to the terminal — in a
file *and* on screen, not just one or the other.

`cl start --fresh "Name"` remains as the way to rotate **one live session now**
without stopping anything else: it asks, retires and relaunches in a single
command, and fails closed if the handoff does not arrive.

Claude only, matching the existing `cl stop`/`cl start` lifecycle boundary.

### 3. `cl handoff` — writing one by hand

Run *inside* a session. It is the way out when text injection cannot reach a
pane at all, and it is the reason `cl stop` can afford to refuse: declining to
stop a session is only reasonable if there is a way to satisfy the requirement.

```
cl handoff < notes.md     # write it, atomically, with the marker appended
cl handoff                # print where to write and what to include
cl handoff --path         # just the path
```

The session name comes from `CL_SESSION_NAME`, which every launch path sets, so
inside a session this needs no argument. An empty handoff is refused — an empty
file satisfies every existence check while saying nothing.

A hand-written handoff is marked as such, and `cl stop` treats it as an
**answer** rather than a leftover: it is honoured instead of swept, and its age
is printed, because the one real hazard is acting on something written weeks
ago and forgotten.

### 4. Rotation hint on `cl --list`

`cl --list` shows an approximate current context size per Claude session and
flags one `rotate` when it passes a threshold or the transcript gets old — the
point past which a full resume costs noticeably more per call than a fresh
start. With rotation now happening on every stop/start cycle, this is mostly a
prompt to rotate a session that has been running a long time *without* one. Thresholds are overridable via `CL_ROTATE_CTX_THRESHOLD` and
`CL_ROTATE_AGE_DAYS`. Codex rows are left blank: that rollout format carries no
comparable usage figure, and guessing one would be worse than showing nothing.

## What you write, and what the tool writes

The tool defines the **mechanism**: when to ask, how to reach the pane, how to
know the answer arrived, and what to do when it does not. It does not define
what a good handoff contains beyond the minimum it must check for.

The default instruction asks for a handoff and nothing else. Anything more —
tidying a task list, trimming notes, house rules about what may be archived —
is a workflow, and belongs to you:

| file | what it replaces |
|---|---|
| `~/.config/claude-session/handoff-prompt.txt` | the instruction sent before a session is killed |
| `~/.config/claude-session/resume-prompt.txt` | the first message a fresh session receives |

Placeholders are substituted literally and never evaluated:

| placeholder | becomes |
|---|---|
| `{{handoff}}` | full path of the handoff file for this session |
| `{{nonce}}` | this request's completion token — **a custom prompt must ask for it**, or `cl` can never confirm the handoff |
| `{{name}}` | the session's display name |
| `{{store}}` | the resolved handoff directory |

Newlines are flattened to spaces: the text is typed into a live TUI, where a
newline submits.

If a custom prompt asks for work *in addition* to the handoff, that work must
happen **before** the handoff is written. The handoff landing is the only
completion signal `cl` has, so anything after it can be interrupted by the kill.

## Where handoffs are written

`CL_HANDOFF_DIR` (default `~/.local/state/claude-session/handoff`) — local by
default, because that is the only location this tool can assume exists. Point
it at a synced folder if you want handoffs to follow you between machines.

That is exactly why a fallback exists: a synced directory can be slow to
appear, only partially hydrated, or briefly absent, and a dataless placeholder
directory can fail to accept a write even though it looks present. Every path
resolves through one function that probes the directory, falls back to
`CL_HANDOFF_FALLBACK_BASE`, and **says so on stderr** rather than silently
writing somewhere that will not be there later. If neither is usable, that is
treated as "could not even ask" and the stop proceeds plainly.

## Dry run and testing

`cl stop --dry-run` and `cl start --fresh <name> --dry-run` print every
handoff, kill, launch and history write they would perform without doing any of
them — no text injection, no kill, no state write, and no directory creation or
write probe against the handoff directory either.

`tests/test-handoff.sh` covers context-size summation, the rotation threshold
and age flag, handoff-directory resolution including an unwritable base,
`--no-handoff`, unrecognised-flag rejection, `--fresh`'s dry-run output and its
unknown-name error, prompt overriding and placeholder substitution, and the
pane-injection contract against real tmux and a real (faked-argv) cmux rather
than stand-ins.
