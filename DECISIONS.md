# Decisions

Form-factor choices that could have gone another way. Each entry records what
was chosen, what it forecloses, and what would reverse it — so a later change
is a deliberate reversal, not an accident.

## 2026-09-15 — a remembered model is keyed by agent AND name, in its own file

**Chose:** `cl model [--codex|--claude] <name> <id>` stores the choice in
`~/.config/claude-session/models.json` as `{"<agent>": {"<name>": "<id>"}}`,
separate from `state.json`.

Keyed by agent as well as name, corrected after review (2026-09-17). Name alone
crossed the agent boundary: with a Claude and a Codex session both called
`API`, `cl --claude API` resolves the ambiguity for the launch and would still
have been handed the Codex model — `claude --model <a-codex-model>`. Session
identity is `(agent, name)` everywhere else here; the store now matches, and a
bare name that two agents share is refused rather than guessed.

Not a field in `state.json`, which was the obvious place: that file is a
snapshot of what was live at the last `cl stop`, and `cl start` consumes and
deletes it. A preference kept there would be erased by the first stop/start
cycle — and `cl new --model` names a session that has no state record yet.

Keyed by name rather than session id because the name is what the user types
and what stays stable; a session resumed into a new transcript keeps its name
and should keep its model.

**Forecloses:** little now. A session must be discoverable for the agent to be
inferred; otherwise the flag is required.

**Reverses by:** deleting `valid_model`/`model_for`/`model_flag`/`set_model`/
`do_model`, the `model` dispatcher arm, the `--model` flag in `do_new`, the
third argument to `resume_cmd`, and the two `model_flag` calls in `do_start`.
The file itself can be left behind; nothing else reads it.

## 2026-09-15 — the model charset is validated, and that makes the quoting untestable

**Chose:** a model id must match `[A-Za-z0-9._:/-]+`, checked both when set and
when read back, and is `printf %q`-quoted where it is spliced into a command
string.

**The honest part:** every value that passes the charset check is already
shell-safe, so the quoting is a no-op and removing it leaves the test suite
green. It is kept as the layer that matters if the charset is ever widened —
a model id containing a space, say. Widening the charset without testing the
quoting would be the actual mistake.

**Forecloses:** model identifiers containing spaces, quotes, `@`, `+`, `=`, or
`#`. No current agent uses such an id; a future one would need the charset
widened deliberately, with a test for the quoting added at the same time.

**Reverses by:** relaxing `valid_model` — and writing the quoting test that
becomes possible at that moment.

## 2026-09-21 — the model lock refuses a stale lock rather than reclaiming it

**Chose:** `models_lock` reports a dead holder's lock and exits, printing the
`rm -f` to clear it. It never unlinks one automatically.

Validating a symlink and then removing its pathname are two operations, and
between them another waiter can acquire — the delete would then destroy a live
claim and put two writers inside the read-modify-write together. The
start-token proof authenticates the object read, not the object later unlinked,
and portable shell has no compare-and-swap.

`acquire_launch` reached this conclusion first and documents it; I implemented
the pattern it rejects, forty lines below the paragraph rejecting it. Caught in
review 2026-09-21.

**Forecloses:** unattended recovery from a writer that died inside a
few-millisecond window. The trade is the same one the launch lock already makes.

**Reverses by:** finding a primitive with atomic ownership transfer — at which
point both locks should change together, not just this one.

## 2026-08-28 — Codex support is a per-session `agent` field, not a second script

**Chose:** `discover()` emits a fifth column, `agent` (`claude` | `codex`), and
every consumer (picker, `--list`, direct launch, state file) carries it.
Launching dispatches on that field.

**Forecloses:** nothing structural. It does mean the script's name
(`claude-session`) and the `cl` alias are now slightly misnamed.

**Reverses by:** removing `discover_codex`, the column, and every agent-aware
consumer — launch dispatch, `session_pid`, tmux naming, the picker/list rows,
the `--codex`/`--claude` flags, and the `agent` field in state. A cross-cutting
removal, not a one-function delete (corrected after review, 2026-09-01).

**Corollary (found in review):** the tmux/cmux session identity is also
agent-qualified — Codex sessions get a `codex_` prefix — because a Claude and a
Codex session may share a display name, and `tmux new-session -A` attaches to
an existing same-named session instead of running the launch command.

**Not chosen:** a separate `codex-session` script. It would duplicate the
tmux/cmux/iTerm plumbing, and the whole point of `cl` is one picker for the
working set regardless of which agent runs in a pane.

## 2026-08-28 — Codex launches with no added approval/sandbox flag

**Chose:** `codex resume <id>` and `codex` are run bare. `CL_CODEX_ARGS` is
purely additive and documented as trusted shell syntax (it is spliced into a
tmux/cmux command string).

**Forecloses:** a "just works like Claude" experience for users who expect
`cl` to pre-approve everything — they must set `CL_CODEX_ARGS` themselves.

**Reverses by:** giving `CL_CODEX_ARGS` a non-empty default.

**Why:** Codex's `--approve-for-me` reroutes approvals through automatic
review; adding it by default would silently override a policy the user set in
`~/.codex/config.toml`. Claude's path keeps `--dangerously-skip-permissions`
because that predates this change and users rely on it; it is *not* the model
for Codex. (Raised in independent review, 2026-08-28.)

## 2026-08-28 — The Codex ● marker is "a local resume process exists", nothing more

**Chose:** `session_pid` for Codex matches argv of a local `codex … resume
<id>` and is used only to refuse a duplicate launch in cmux.

**Forecloses:** using that pid as a kill target or as an idle/busy signal.
Codex threads also run under an app-server daemon, the desktop app, and
`--remote` clients, none of which show that argv; and the npm launcher is a
node wrapper plus a native child that both match. `cl stop`/`cl start` are
therefore Claude-only until a thread-status interface exists.

**Reverses by:** replacing `session_pid`'s codex branch with a query against
an app-server/thread-status API, once one is stable.

## 2026-08-28 — Codex discovery is a version-bound adapter over private files

**Chose:** read `session_index.jsonl` (last line per id = current name) and
find the rollout under `sessions/` only, in one isolated function that fails
soft per record and prints a diagnostic only when the layout is unrecognised.

**Forecloses:** nothing — but it *is* coupled to Codex CLI 0.150.0's storage.
There is no supported listing command with machine-readable output at that
version, and `state_5.sqlite` exists alongside the JSONL, so the JSONL may not
stay the source of truth.

**Reverses by:** swapping `discover_codex`'s body for a CLI/JSON listing when
Codex ships one. `tests/test-discover.sh` is the contract to keep passing.

**Not chosen:** querying the SQLite database directly (trades one private
schema for a less inspectable one) or searching all of `~/.codex` for
rollouts (would resurrect archived sessions).

## 2026-08-28 — `cl new --codex "Name"` labels the tab; it cannot name the thread

**Chose:** accept the name for tab/tmux labelling and print a `/rename`
reminder, rather than reject the command or pretend parity with Claude's
`--name`.

**Forecloses:** the named session appearing in `cl --list` before the user
renames it.

**Reverses by:** passing the name through, if Codex gains a launch-time name
flag.

## 2026-08-28 — Codex sessions are excluded from `cl stop` / `cl start` until a thread-status source exists

**Chose:** `save_state`, `do_stop`, and `do_start` filter to `agent == claude`.
Codex sessions are discovered, listed, resumed, and created — but never
killed or relaunched by the lifecycle commands.

**Forecloses:** a single `cl stop` / `cl start` that cycles a mixed working
set. Codex panes are stopped and restarted by hand for now.

**Unblocking condition:** a Codex CLI interface that reports, for a session
id, whether a thread is live, which client owns it, and whether it is
mid-turn — a listing/status command with machine-readable output, or an
app-server query. Argv matching cannot provide any of those (see the
marker entry above), so building stop/start on it would produce exactly the
false-live, false-idle, and wrong-pid-killed failures reviewed on 2026-08-28.

**Reverses by:** replacing the `agent == claude` filters with a call to that
interface, plus a Codex branch in the busy check and kill path.

## 2026-09-01 — Session ids are validated at discovery and quoted at every command boundary

**Chose:** `discover_claude` drops any id that is not `[A-Za-z0-9._-]+`;
`discover_codex` drops any id that is not a 36-character UUID; `resume_cmd`
and `do_start` additionally `printf %q` the id where it enters a tmux/cmux
command string or an `eval`'d exec line.

**Forecloses:** nothing — no real id fails the checks.

**Reverses by:** nothing should. If Codex changes its id format, widen
`valid_codex_sid`; do not remove it.

**Why:** ids are data read from files another process can write. Before this,
a crafted `session_index.jsonl` row (or a transcript filename) reached
`eval "exec $cmd"` verbatim and ran as the user on selection. The Claude
path had the same exposure before Codex support existed; the adapter copied
it. (Found in independent review, 2026-09-01.) `tests/test-discover.sh` now
carries fixtures whose ids are shell syntax and asserts they never become rows.

## 2026-08-28 — Framework procedures ship as several `when-*.md` files, installed by copy, never wired into CLAUDE.md

**Chose:** `framework/` holds one procedure per file with flat `type: when`
frontmatter. `install.sh` copies them to `~/.claude/framework/` and prints the
`@~/.claude/framework/<file>` import line; it does not edit `~/.claude/CLAUDE.md`.

**Forecloses:** a one-shot "install and it just applies" experience — the user
adds the imports themselves.

**Reverses by:** concatenating the files into one, or adding a sentinel-guarded
import block to CLAUDE.md the way the shell rc is handled. The copy's ownership
semantics — package-managed, backed up on divergence, never deleted when
edited — reverse by switching the destination to a symlink into the repo
(then the repo owns it outright) or to a versioned vendor directory with user
overrides elsewhere. (Ownership semantics added after review, 2026-09-01: the
first version overwrote and deleted edited files silently.)

**Why several files:** a memory tool that indexes `when-<activity>.md` can absorb
them with a move, not a rewrite. **Why no CLAUDE.md edit:** that file is the
user's instantiation — their channels, their names. An installer that writes
into it is writing content, and the repo's rule is that installers write
scaffolding only. **Why copy:** same as the binary — the installed layer must
survive the repo not being present.

## 2026-08-31 — Mixed-shape procedures use angle-bracket shape slots, distinct from capability slots

**Chose:** procedures whose every line mentions a tool, flag, tag key, or
branch name (`when-presenting-infrastructure-code`, `when-running-an-iac-wrapper`,
`when-committing-on-a-personal-branch`, `when-presenting-code`,
`when-deleting-cloud-resources`) keep the procedure and replace each such
name with `<shape-slot>`. `{capability-slot}` still means "what kind of tool
you have"; `<shape-slot>` means "what it is called." Both are bound in the
same table beneath the import.

**Forecloses:** reading these five files standalone as usable checklists —
they need a bindings table to be concrete.

**Reverses by:** inlining a binding into the shape where one value turns out
to be universal (e.g. if every user's `<main-branch>` is `main`, drop the
slot) — or, the more serious case, **removing a procedure from the generic
layer** when what differs between tools is behaviour rather than a name:
substitution cannot bridge a missing command grammar. Such a procedure either
declares the behaviours it requires and is omitted when they are absent (the
IaC wrapper does this now), or moves out to a tool-family template.

**Why:** the alternative — writing each procedure twice, once per cloud or
tool — is the duplication the framework exists to avoid. When in doubt a
name was slotted, not kept: a slot that turns out unnecessary costs one
table row; a kept name that turns out to be one employer's is a public leak.

## 2026-08-31 — No leak-check script or fixture lives in this repo

**Chose:** the grep used to verify that framework files carry no employer,
product, tag-key, or tool inventory is run from the maintainer's private
side and its result pasted into the review. It is not committed here.

**Forecloses:** a CI job that enforces the public-content rule from inside
this repo.

**Reverses by:** adding a check that reads its pattern list from an
untracked, gitignored file (or from the maintainer's private config repo) —
never from source in this repository.

**Why:** the pattern list *is* the inventory the check exists to keep out. A
`leak-check.sh` here would publish every name it greps for. Do not add the
grep to CI.

## 2026-09-01 — Shell wiring lives in an installer-owned snippet; ~/.zshrc gets only a source guard

**Chose:** `install.sh` writes `~/.local/share/claude-session/shellrc` (a file
nothing else touches) and appends a single guarded `source` line to a regular
`~/.zshrc`. A symlinked `~/.zshrc` — a dotfiles manager's file — is never
appended to; the installer prints the guard line for the managed file to carry.
Old inline blocks migrate on rerun.

**Forecloses:** a self-contained `~/.zshrc` edit; users of managed dotfiles add
one line themselves (or their manager's repo carries it).

**Reverses by:** inlining the snippet back into the sentinel block.

**Why:** appending real content into a file another tool owns fails when that
tool replaces the file — measured 2026-09-01: a dotfiles manager symlinked
`~/.zshrc` to its repo copy and the appended alias silently vanished. The
invariant is one writer per file. Same class as the installer-clobbers-edits
finding earlier that day, from the other direction.

## 2026-09-01 — The picker never hides rows silently

**Chose:** the fzf list uses adaptive height (`--height=~100%`) — it grows to
fit the list; when it must scroll, fzf's counter and scrollbar say so.

**Why:** a fixed `--height=45%` rendered ~10 rows with no overflow indication;
a session below the fold looked absent and cost a real search. A list must
never render a state that looks identical to "that's everything" when it isn't
— the same silent-truncation family as the seed-template and dry-run-guard
findings this month.

## 2026-09-11 — In iTerm the agent is the tab's own process; tmux is opt-in

**Chose:** `use_tmux()` decides per launch — false in iTerm2 (unless
`CL_TMUX=1`), true elsewhere when tmux exists, and the cmux path is untouched.
`cl stop` / `cl start` gained the machinery that tmux used to provide for free.

**Forecloses:** detach/reattach in iTerm. Closing the tab ends the session and
Ctrl-Z suspends the agent; `cl <name>` resumes by session id, and a
never-messaged `cl new` session is unreachable by name until its first message.

**Reverses by:** `export CL_TMUX=1`, or flipping the default inside
`use_tmux()`.

**Why:** iTerm2's Claude Code integration keys its profile triggers on the
tab's foreground job name and locates the tab from the agent's tty. Inside tmux
the job is `tmux` and the tty is a tmux pty, so both signals miss and the
integration silently does nothing — the same reason the cmux path already
skipped tmux.

**Three repairs this forced, each a silent failure if skipped:**
1. `do_stop` bailed with "no tmux server — nothing to stop" and exited 0. With
   no tmux that is no longer evidence of an empty fleet; it now also requires
   no cmux and no live agent process.
2. Only the tmux branch of `do_stop` closed the iTerm tab, so without tmux
   every session left a dead `[Process completed]` tab behind.
3. `session_pid` matched only `--resume`/`--session-id`, so a session created
   by `cl new` (argv carries `--name`, no id) was invisible: `tmux has-session`
   had been covering it. `cl stop` would have saved and killed everything
   *except* the newest session, silently.
4. Nothing refused a duplicate outside cmux, because `tmux new-session -A`
   had been doing it. `cl stop` leaves a busy session running on purpose, and
   `cl start` then opened a tab for it — a second agent on one transcript.
   The refusal now covers every non-tmux launch, and `cl start` skips live
   entries when building its tab list.

**How a session with no id in its argv is identified — a launch registry, not
a name match.** The first attempt matched the name inside `ps` output. `ps`
renders the command as text, so `--name Solo` is a substring of `--name Solo
Two`: `cl stop` could kill the wrong agent. Instead each non-tmux launch
records `pid + process start time` under
`~/.config/claude-session/pids/<key>` immediately before `exec` — which keeps
both values — and a record is trusted only while the pid is alive *and* its
start time still matches, so a recycled pid is detected and the record
deleted. No command-text parsing anywhere. Only sessions this tool launched
outside tmux are registered, which is exactly the set nothing else can
identify. (Design chosen after review flagged the substring bug; the cheaper
"refuse ambiguous matches" floor was rejected because this is a kill path.)

Two further properties, both added after a second review round:

* **The key is a digest of agent + the exact name**, not `tmux_name`'s
  sanitiser. That sanitiser maps `A B` and `A.B` to one identity — harmless
  under tmux, where `new-session -A` made colliding names share a single
  session so two owners could not exist, but bare they both launch and the
  second record overwrites the first, handing one session's pid to the other's
  kill path. The record also stores the agent and name, and is rejected if
  they do not match, so a digest collision could not kill the wrong session
  either.
* **Acquisition is atomic**, guarded by `mkdir`. A check followed by a write is
  not: two tabs running `cl <name>` together could both see nothing, both
  write, and both exec an agent on one transcript. `tmux new-session -A` had
  been that arbiter; without tmux this is. A launcher that dies holding the
  lock is reclaimed after a few seconds, which is safe because the record
  inside is still validated.

**Acquisition fails closed.** If the registry directory, the claim lock, the
start token, or the ownership record cannot be created *and verified*, the
launch is refused with a specific reason. The first version returned success
in those cases, which launched an agent the registry could not identify — no
duplicate protection, and `cl stop` might skip it: precisely the failure the
registry exists to prevent. An occasional refused launch is the safer side.

**A held claim is reclaimed only on proof.** The lock is a symlink whose target
names its owner (`pid:start-token`), which `ln -s` creates atomically, so there
is never a window where the lock exists but its owner is unknown. A waiter
reclaims only when that owner is gone or its pid was recycled — never on age,
because a holder merely slow in `ps`/IO would be displaced and two launchers
would enter the critical section together. A non-symlink at the lock path is
refused outright: `ln -s target dir` creates the link *inside* the directory and
reports success, which would hand a launcher a lock it does not hold.

**A stale claim is reported, never auto-cleared.** Validating the lock symlink
and then unlinking its pathname are two operations: between them another waiter
can reclaim and establish a live claim, and the delete would then destroy *that*
claim and let two launchers into the critical section. The start-token proof
authenticates the object read, not the object later unlinked, and portable shell
has no compare-and-swap to close that gap — a second read just before the
unlink narrows it without fixing it. So a stale lock fails closed with the dead
holder's pid and the exact `rm -f` to clear it. A launcher has to die inside a
few-millisecond window to leave one.

*Considered and rejected:* a second "reclaim" lock making the unlink exclusive.
It does close the race, but it has its own stale case, and recursion is the
wrong shape for a kill path. Refusing costs a person five seconds, once, in a
situation that should never arise.

**Nothing mutates a record except under the claim.** `registered_pid` is
read-only: it used to delete records it judged stale, which is the same
validate-then-unlink-a-pathname race — a launcher holding the lock can write a
fresh record between the read and the delete, and the cleanup would remove the
*new* owner's registration, leaving that agent untracked and duplicable. A
stale record is inert (every reader validates it) and `acquire_launch`
overwrites it under the lock. `clear_launch` likewise deletes only a record
that still names the exact pid being retired, under the claim — `cl stop`
kills, and a new launcher can register before cleanup runs.

**Cleanup compares the whole owner, and both holders share one lock format.**
A replacement process can reuse a dead owner's pid number — that is why the
record carries a start token — so cleanup matches pid *and* token *and* agent
*and* name, and `do_stop` captures the token before the kill because it cannot
be read back out of a dead process. The lock target is produced by a single
`claim_token`, used by launcher and cleanup alike: when the cleanup wrote its
own literal instead, `acquire_launch` parsed it as a start token, judged a
running cleanup to be a dead holder, and told the user to delete a valid lock.
No behavioural test can catch that — the cleanup's lock exists for
microseconds — so the duplication is removed rather than tested around, and
what remains asserted is the shape the shared function produces.

**Identity is re-proved at the destructive boundary, and ownership outlives the
signal.** `cl stop` can sit on a "kill it anyway?" prompt for as long as a
person takes to answer; the original process can exit in that window and its
pid be reused, so `retire_process` re-checks pid+start-token immediately before
signalling and reports "exited while stop was deciding" instead. And `kill`
returning 0 proves delivery, not exit — while an agent runs its shutdown hooks
it is still alive, and its record is the only thing preventing a second one, so
the record is retired only after the exact process is confirmed gone (bounded
wait; otherwise it is left in place).

**`in_cmux` requires the cmux app to actually be running.** A tmux server
started under cmux keeps `CMUX_*` in its *global* environment and hands them to
every pane opened later — including panes opened from another terminal long
after cmux quit. An environment-only test therefore reported "in cmux" inside
iTerm, which would route launches down the cmux branch, skip the iTerm tab
tagging, and dial a dead socket. Non-cmux launches also strip `CMUX_*` before
exec, and `tmux_setup` clears them from the server's global environment, so the
staleness does not propagate to the agent or to cmux's own hooks.

*How the check is made:* cmux is asked to affirm **this shell's** workspace id
— it must appear in the live instance's own `workspace list --json`. Presence
of a cmux app is not enough: if cmux has since reopened, or a second instance
is running, stale ids inherited from a dead context look authoritative again
and the launch goes down the cmux branch anyway. An id cmux cannot affirm means
stale, and the normal host path is taken.

The comparison is structural — jq against `.workspaces[].id` — not a substring
of the raw JSON: an id like `workspace` is a substring of a live
`a-real-live-workspace`, and any id can also appear in a title, a directory or
some other field. jq is already required for stop/start; if it, the command, or
the schema is missing, the context is simply unaffirmed.

Three earlier attempts are recorded because each looked right: `pgrep -f` on the
app path matched *nothing* on a machine where cmux was demonstrably running
(`cmux.app/Contents` matched, one character more did not) and `pgrep -f` also
matches the shell running the check, so a pattern can find itself; a
literal `ps` snapshot fixed that but still only proved "a cmux exists"; and a
substring test over the workspace JSON proved only that the id appeared
*somewhere* in the document. Surfaces
cannot be validated this way — cmux lists them by ref, not uuid — so a pane
carrying only `CMUX_SURFACE_ID` counts as unaffirmed, the safe direction.

**On testing this:** a wall-clock race between two `cl` invocations does not
prove mutual exclusion — measured, it passes even with the lock removed,
because process startup jitter serialises the two anyway. The suite therefore
proves the property directly (while a claim is held, `acquire_launch` must
block), and keeps the two-launcher race only as a smoke test of the whole
path.

**Also fixed, found by the new tests:** `do_stop`'s "is this agent owned by a
tmux server?" guard compared the parent's whole command line against `*tmux*`,
so any parent whose arguments merely mentioned tmux silently skipped the kill.
It now compares the parent's executable name.
