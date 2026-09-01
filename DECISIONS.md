# Decisions

Form-factor choices that could have gone another way. Each entry records what
was chosen, what it forecloses, and what would reverse it — so a later change
is a deliberate reversal, not an accident.

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
