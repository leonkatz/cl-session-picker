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

> **At most one unconsumed handoff per session, and a handoff counts only
> when it is complete.**

Complete means its **last non-empty line** is the marker `cl` asked for:

| marker | written by |
|---|---|
| `<!-- cl:clho:… -->` | a session answering a stop request (the nonce) |
| `<!-- cl:manual:<ts>@<sid> -->` | `cl handoff`, stamped with its own session id |

Terminal position is the point. A handoff is meant to be written to a temp file
and renamed, so a complete one appears whole — but an agent that writes straight
to the target and is killed mid-write leaves a **real, readable, truncated
file**: plausible prose cut off mid-sentence, with no marker, because the marker
is written last. Presence alone cannot tell that from a good handoff, and a
replacement session seeded from one continues from a lie without knowing. A
partially-synced file from a shared store fails the same way.

So `cl start` rotates only from a file carrying a valid terminal marker.
Anything else is moved to `<store>/incomplete/`, reported loudly, and the
session **resumes** instead — the floor, with its whole transcript intact.

A prior handoff is never swept merely to make room: nothing invalidates it
until a newer one actually replaces it, and the agent's atomic rename does that
only when the new handoff is finished.

### Spending a handoff: one move, to a permanent path

Rotating renames the active handoff **straight to its permanent home** under
`<store>/consumed/`, and hands *that* path to the replacement. The pathname
given to another process is never renamed again.

An earlier design staged it in a `.claims/` directory and moved it to
`consumed/` once the launch was accepted. That was wrong in a way the tests
could not see: the replacement's first message had already been built from the
staging path, so the second move renamed the file out from under a prompt that
was already on its way to the agent. **Every rotation told the new session to
read a path that no longer existed.** The tests all checked the *store* — the
active file gone, `consumed/` one file richer — and passed throughout. What
none of them checked was whether the path in the agent's own argv still
resolved.

Destination names are unique **by construction** (timestamp, pid, two random
draws). A check-then-move — "pick a name nothing occupies, then rename onto it"
— is not collision-safe: two writers in the same second can both see the same
free name.

The move is a `rename`, so claiming is atomic: two starts racing for one
handoff produce exactly one rotation and one ordinary resume.

**Rolling back.** If the launch is refused, the handoff goes back to the active
path — but **only if nothing newer is there**. While a rotation is in flight the
old session (or `cl handoff`) can publish a newer handoff at the freed path, and
moving the older one back on top of it would destroy the more recent answer. In
that case the older one stays filed and says so.

**What "accepted" can honestly mean.** On an `exec` path the launcher replaces
itself with the agent, so it can never observe the agent running. What it can
establish is: launch ownership granted, the working directory reachable, and the
agent binary runnable — all three preflighted, so a missing agent or a vanished
directory rolls the handoff back instead of spending it. An `exec` that fails
after that still spends it; closing that would need the replacement to
acknowledge, which nothing here does. The docs say what is checked rather than
claiming more.

Where the launch *is* synchronous — a detached tmux session, a cmux workspace —
the launching process sees the backend answer, and a refusal rolls back and
**keeps the session's row in the restart list**, so `cl start` simply retries it
and the command exits non-zero. Without tmux the agent is started by the *tab*,
in another process: "the terminal accepted the text" is not "an agent started",
so there the parent leaves the handoff untouched and the tab claims it after
`acquire_launch` grants ownership. A tab that never runs spends nothing.

### Which way a session comes back is recorded, not inferred

`cl stop` writes `resume_only` on the saved row when it could not get a handoff,
or when `--no-handoff` was given. `cl start` obeys the row.

Inferring it from "is there a handoff file?" was not enough. A stop whose
request failed can leave an *older* complete handoff in place — so the next
start would rotate from notes predating everything the session did since, while
`cl stop` had already printed that it would resume. And `--no-handoff`'s attempt
to clear a pending handoff can itself fail, silently reversing an explicit
choice. With the decision on the row, a clear that fails cannot change what
happens next.

### Whose handoff is it?

`cl handoff` stamps the writing session's id into its marker
(`<!-- cl:manual:<ts>@<sid> -->`), taken from `CL_SESSION_ID`, which every
launch that knows the id sets. A rotation refuses a handoff stamped with a
*different* id: it belongs to a previous occupant of that name. Without this, a
`cl handoff` that began writing before a rotation and finished after it would
drop the predecessor's notes into the freshly-emptied path, and the next start
would seed a replacement from them.

The id is **passed in, never looked up by name**. A lookup would be no evidence
at all: the display name is stable across rotations, so after one the newest
session under that name is the *replacement* — and a predecessor still finishing
its handoff would stamp its successor's id onto its own file, making a stale
handoff look current. A session with no id yet (a freshly rotated one) stamps
none. Unstamped markers are accepted for any occupant: honest and permissive
beats confidently wrong.

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
nonce each round, because a session mid-task may not read the first one. All of
this shares **one budget for the whole stop** — `CL_HANDOFF_BUDGET`, 300
seconds by default, not per session. Attempts × timeout × sessions is how a
handoff feature turns an eight-session `cl stop` into a half-hour one.

**A session whose handoff never lands is still stopped.** It comes back by
resuming rather than rotating, and `cl stop` says so plainly. Rotation is the
optimisation; resume is the floor; a failed optimisation should be loud, not
redefine what "stop" means. `cl stop` is the command you run before a reboot or
a version upgrade, and the session least able to answer a handoff request is
the wedged one you most need gone.

`cl stop --require-handoff` (alias `--rotate`) opts into the opposite for the
cases where rotation is the whole point: sessions without a handoff are left
running, and the command **exits non-zero** so a script or a shutdown hook
cannot mistake it for success.

`cl stop --no-handoff` skips the request *and clears any pending handoff*, so
its promise — the session comes back exactly as it was — is actually true.
Skipping has to be a durable decision for this cycle, not something inferred
from an absence that might predate this stop.

An unreachable pane fails on the first attempt rather than burning the rest:
retrying cannot fix "there is nothing to type into".

### 2. Rotation on `cl start`

`cl start` brings back everything in the last snapshot. Per session, the
presence of an unconsumed handoff decides how:

| | |
|---|---|
| **complete handoff present** | claim it, start a **new** agent under the **same name**, in the same directory, through the same wrapper selection, hand it the file as its first message, and commit the claim once the launch is accepted |
| **no handoff, or an unusable one** | `--resume <sid>`, exactly as before (an incomplete or foreign handoff is filed under `incomplete/` first) |

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
file satisfies every existence check while saying nothing. `cl handoff` writes
to a temp file, appends the `manual` marker as the last line, and renames, so
what it produces is always complete by construction.

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
| `{{nonce}}` | this request's completion token — **a custom prompt must ask for `<!-- cl:{{nonce}} -->` as the file's last line**, or `cl` can never confirm the handoff and will never rotate from it |
| `{{name}}` | the session's display name |
| `{{store}}` | the resolved handoff directory |

Newlines are flattened to spaces: the text is typed into a live TUI, where a
newline submits.

If a custom prompt asks for work *in addition* to the handoff, that work must
happen **before** the handoff is written. The handoff landing is the only
completion signal `cl` has, so anything after it can be interrupted by the kill.

## What lives in the store

| path | holds |
|---|---|
| `<store>/<Name>.md` | the one active, unconsumed handoff for that session |
| `<store>/consumed/` | handoffs a replacement actually started from |
| `<store>/incomplete/` | files that were not usable — truncated, or written by a different occupant of the name |

Nothing is ever deleted. An incomplete handoff is still real work and is the
evidence of what went wrong.

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
