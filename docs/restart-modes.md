# Restart modes — design

Status: phases 1 and 2 implemented — the four modes for Claude, mode storage
and migration, compact-resume end to end, and Codex `fresh` (below) — and
`cl compact` (steps 2-5 without a stop, below). The design review's findings
are folded in and marked **(R)**.

Where phase 1 settles something this page leaves open:

- **Log rows.** The rotation log stays one row per stop, so `rotate stats` keeps
  counting stops. The per-session facts — path taken, reason, `preTokens`,
  `postTokens` — are four comma-list columns in the same session order.
- **"Mixed" weeks.** The row's mode is the mode *asked*; fallbacks go in the
  paths column. `on`/`off` rows read as `handoff`/`resume`. A week whose mode
  changed once is shown as `A->B`, and only interleaved modes are `mixed`.
- **"The last record"** for the token means the last *conversation* record
  (user or assistant): Claude also writes metadata records after a turn.
- **Unreachable or unwatchable sessions.** No pane to type into, or no
  transcript to watch: fall back to `handoff`, the route `cl handoff` can still
  answer by hand. `/compact` that cannot be typed after the token: resume as-is.
- **A failed resume at start** leaves any handoff in the store untouched — it is
  neither rotated from nor consumed.
- **A hand-written handoff is not used in compact-resume mode.** `cl handoff`
  inside a compact-resume session does not make it rotate: the stop compacts
  it and files any waiting handoff under `consumed/`. To rotate from one, set
  the session to `handoff` (`cl mode "Name" handoff`) first. Only a session
  that falls back to a handoff (no `cl-done` reply in time, or no pane to
  type into) honours one written by hand.
- **"At rest" after a compaction** is judged on the last *conversation* record
  too: Claude Code follows the Compacted output (string content, wrapped in
  ANSI SGR codes) with attachment and metadata records. Only that output, or
  the token reply for a session that compacted on its own, counts — never a
  free-text mention of the hook, which a tool_result can contain.

## What it is for

A long-lived session carrying 700-900k tokens of context makes every turn
expensive. Today `cl stop` / `cl start` offers two ways back: resume as-is
(full context, full cost) or a handoff to a fresh session (small, but rebuilt
from a note the session wrote). A third way keeps the session's own memory and
still comes back small: **compact it before stopping, then resume it**. A
resumed session loads from its latest compaction. One real compaction measured
968k → 22k tokens in 88 seconds.

The stop still matters: it is how terminal, MCP, plugin, settings and hook
updates take effect.

## Modes, per session

| mode | on `cl stop` | on `cl start` |
|---|---|---|
| `compact-resume` | run the pre-compact prompt, then `/compact`, wait for the compaction, stop | `claude --resume <sid> "<first prompt>"` |
| `handoff` | today's rotation: ask for a handoff, stop | fresh session that reads the handoff |
| `fresh` | stop; no handoff | a NEW session; the old one is not resumed |
| `resume` | stop | `claude --resume <sid>` (today's rotation `off`) |

Default for Claude: `compact-resume`. Default for Codex: `resume` (as today).
Codex supports `resume` and `fresh`; `compact-resume` and `handoff` are
Claude-only for now.

### Storage and migration

`rotate.json` keeps its shape (`{"default":…, "sessions":{"claude":{name:…}}}`)
with its values widened. `on` reads as `handoff` and `off` as `resume`, so an
existing file means exactly what it meant. Only the built-in default, used when
there is no stored value, becomes `compact-resume`. Codex gains a section of its
own (`sessions.codex`), so `fresh` can be set for a Codex session; the rotate
CLI's refusal of `--codex` is lifted for `resume|fresh` only.

`cl rotate <name> on|off` keeps working as aliases. A new `cl mode <name>
<mode>` sets the others. `--no-handoff` still forces `resume` for one stop, and
`--require-handoff` still forces `handoff`.

The mode `cl stop` actually carried out is written to that session's
`state.json` row as `mode`, next to `resume_only`, so `cl start` does what the
stop did rather than re-deriving it.

## compact-resume, step by step

Every typed line is short and goes through the existing delivery check
(`handoff_ask_mark` / `handoff_ask_seen` / `handoff_poll_marks` / resend). No
second sender is written.

1. **Plan (PASS 1).** For each `compact-resume` session, record its transcript
   and its byte size: the baseline.
2. **Pre-compact request (PASS 2).** Always sent. The full text goes into
   `<store>/<name>.precompact` and a short pointer is typed. It always ends by
   asking for an exact reply token, `cl-done:<nonce>`, as the last thing the
   session writes **(R)**: that token is the only proof that the turn finished,
   so it cannot depend on there being a workflow. The optional workflow text
   comes from `~/.config/claude-session/precompact-prompt.txt` (for example
   "update your session board"); by default there is none.
3. **Wait for the token**, in parallel. It counts only as the exact **last
   line of the last text block** of the session's final reply (the assistant
   records after the last user record, the last conversation record among
   them), with **no `tool_use` anywhere in that reply** in any block order,
   and with the file size stable across two polls **(R)**. Reading the request
   file puts the nonce in a `tool_result`, which is a `user` record, so the
   delivery check's matcher must not be reused for this. The idle check of
   step 6 uses the same rule for its token arm.

   This is **cooperation, not a runtime signal**. Claude Code writes no
   "turn ended" record, so the evidence is that the session did what it was
   asked (the token last, no call outstanding) and then went quiet for two
   polls. A session that writes the token early, or new input that starts a
   turn between the check and the `/compact`, is outside what cl can see. The
   gap is short — the pane re-check and the send — but nothing bounds it;
   typed input queues behind a running turn rather than interrupting it.
   **Before anything is typed** (the request, a retype of it, and again
   before `/compact`) the pane is checked to be this session; see "Which pane
   is this session" below. A pane that is not is given nothing.
4. **Type `/compact`**, once, as soon as the token arrives. There is no busy
   check **(R)**: `claude_busy` stays true for minutes after a turn (the
   lingering helper child), so a gate would starve every session. The token is
   the proof the turn ended, and typed input queues safely. The one hazard is
   typing it twice, which never happens. A byte mark is taken just before
   typing.
5. **Confirm the compaction**: a `compact_boundary` record after that mark with
   `compactMetadata.trigger == "manual"`, or the `Compacted` command-output
   record **(R)**. A plain count would be fooled both ways. A pre-compact turn
   at ~1M tokens can trigger an AUTO compaction, which would pass the check
   instantly, kill mid-compaction, or lead to compacting a 20k summary again.
   So if any boundary appears after the baseline before step 4, `/compact` is
   skipped: the goal is already met.
6. **Stop it**, without the "looks mid-task, kill it anyway?" prompt, but only
   once it is idle since the compaction: the last record is the `Compacted`
   output or the compact SessionStart hook record, and the size is stable
   **(R)**. That is passed to `retire_session` as an argument.

The log records `preTokens` and `postTokens` from the boundary record itself;
`context_size` still reads the pre-compaction figure afterwards **(R)**.

On `cl start` the row's `mode` is `compact-resume`: resume with a first prompt
passed as an argument, never typed (from `resume-after-compact-prompt.txt`; a
one-line built-in default says it was restarted and should carry on). The mode
also travels in the tab command for the bare-iTerm path, as `--rotate-from`
does.

**A failed resume never rotates from a handoff (R).** In this mode no handoff
was requested, so any handoff present predates the cycle: exactly the stale
case `mark_resume_only` guards against. Before resuming, a preflight checks
that the transcript exists and that its last boundary is the one the stop
recorded on the row. On tmux, `has-session` is polled about 5s after launch. A
failure resumes plainly and is reported.

### Which pane is this session

A tmux session at the right name is not proof: names collide, and a name
match is all liveness checks. A cl stamp (`@cl_agent`/`@cl_sid`) is not proof
either: it is session-scoped, while typing to `=<session>:` reaches whichever
pane has focus. So the evidence is always a **process tied to this session's
id** — cl's launch record bound to name and id, Claude Code's registry entry
(pid, session id and start time all matching), or a verified Claude client
whose argv resumes exactly that id — running in the place cl types into.
`compact_target_bound` returns that place, and only it is typed into.

"A verified Claude client" is read from the kernel, never from `ps`
(`proc_identity`: libproc's `proc_pidpath` for the image actually executing,
`sysctl KERN_PROCARGS2` for argv with its real boundaries; `/proc` on Linux;
through `python3 -I`). The image must be Claude Code's
(`…/claude/versions/<version>`, or named `claude`, or node running
`…/@anthropic-ai/claude-code/cli.js`); `--resume <id>` or `--session-id <id>`
must be two adjacent argv elements; `--fork-session` disqualifies. A Python
sleeper with `--resume <id>`, or `exec -a 'claude --resume <id>' /bin/sleep`,
is not Claude. An identity that cannot be read (no python3, or the kernel
refuses) is no evidence. What this cannot stop is a program deliberately
installed under one of those names; it stops anything that merely mentions
one. The same check is what `session_pid`, and so every kill path, reads.

| what sits at the name | result |

| what sits at the name | result |
|---|---|
| a tmux session one of whose panes runs (or is an ancestor of) the tied process | typed into **that pane, by its id** (`send-keys -t %N`), whichever window has focus |
| …and stamped as another agent, or another session's id | **refused**: an explicit mismatch, reported |
| …stamped Claude with no id yet (`cl new`), or unstamped, with no tied process in any pane | **refused**: a stamp proves a launch, not this transcript |
| no tmux session: the tied process on a terminal (the tagged-iTerm route) | typed into the tagged iTerm session **only if it is on that process's tty**, checked by the same script that types |
| no tmux session, and no tied process on a terminal | **refused**: cannot tell |

The first proof fixes the destination for the whole run. It is proven again
before a retype of the request and before `/compact`; a session found
anywhere else then, or not at all, is refused, so neither a focus switch nor a
new pane at the name can redirect what is typed.

A refused session in a stop **resumes as-is**: not a handoff, whose ask would
go into the same pane. Under `cl compact` it is not compacted. Either way the
reason (`foreign-pane`, `unverified-pane`) is logged or reported. The check
covers typing only; what the stop later retires is retire_session's own rule.

### Timing

Measured: 88-137s for ~1M → 20k, plus a pre-compact turn at ~1M context. So
`CL_COMPACT_TIMEOUT` defaults to **600s**, for all sessions at once, kept apart
from the handoff budget **(R)**. Worst-case wall clock for a stop is therefore
`CL_COMPACT_TIMEOUT + CL_HANDOFF_BUDGET` plus dispatch.

### Fallbacks

| what went wrong | what happens |
|---|---|
| no `cl-done` token in time | skip `/compact`; fall back to `handoff` |
| a boundary appears before `/compact` | `/compact` skipped; treated as compacted |
| no manual boundary in time after `/compact` | **resume as-is**, not a handoff: an ask would queue behind the compaction and be written from the 20k summary **(R)** |
| resume fails at start | resume plainly, report; never rotate from an unrequested handoff |
| `--no-handoff` | **skips compaction too**: stop now, resume as-is (the fast stop) |
| `--require-handoff` | forces `handoff` for this stop |

Each stop logs one line per session: the mode asked, the path taken, why, and
`preTokens` / `postTokens`. It goes in the rotation log under a new versioned
header (`_ROTATION_LOG_HEADER_V2`), with a migration arm like the existing ones.

### Migration: every reader of on / off / n/a (R)

`_rotate_valid`, `rotate_default`, `rotate_for`, `rotate_source`,
`stop_rotate_resolve`, `rotate_env_value`, `do_rotate`; `do_stop`'s `= "on"`
gates in PASS 1 and 2, and its `n/a|off|else` case in PASS 4, where an unmapped
value would fall into the handoff branch; the dry-run text; `log_mode`;
`rotate_cell` and the `--list` column widths (`compact-resume` is 14 characters,
so the cell shows a short form: `compact`, `handoff`, `fresh`, `resume`);
`rotate_stats` and its "mixed" logic, which would otherwise call every week
mixed and lose the comparison. `mark_resume_only` matches rows by name only, so
the new `mode` field is written by name AND agent. The tests that assert literal
`on/off/mixed` are updated alongside.

## fresh, for Codex

The lane watcher is the hard part, and so is ownership: launching an unnamed
thread gives cl no id, so `registered_pid` and `tmux_owned` reject it, the next
`cl stop` reports it stopped while it runs, and the election keeps the old
thread **(R)**. So `fresh` creates the thread first and then takes the ordinary
resume path:

1. `codex app-server`: `thread/start` returns the new `thread.id`;
   `thread/name/set` gives it the session's name; read the name back.
2. Archive the old thread (`codex archive <old-id>`) **before** anything re-arms,
   so the election cannot pick it. (This holds on the tmux path. In the
   bare-iTerm shape `cl start` re-arms before the tab runs steps 1-4, so the
   election can briefly pick the old thread; it heals on the new thread's
   first SessionStart — see the bare-tab note below.)
3. Rewrite the state row's sid to the new id.
4. Let the ordinary path run `codex resume <new-id> "<first prompt>"`. Every
   existing ownership mechanism then works unchanged, and the first turn fires
   the repo's SessionStart hook, which elects the new thread by `session_id`.
   `coord-rearm` is a backstop only.

To verify while building: that `thread/start` writes a rollout `discover_codex`
sees, and that the first turn fires SessionStart. The lane's unanswered notes
are re-offered to the new thread by the watcher's own re-send.

### Where phase 2 settles something

- **Verified against Codex 0.163.0**, in a throwaway `CODEX_HOME`: the method
  names and params are as above (`thread/start {cwd}` → `result.thread.id`;
  `thread/name/set {threadId, name}`; `thread/read {threadId}` →
  `result.thread.name`), after the usual `initialize` / `initialized`. The
  server must be kept open while a request is in flight — EOF on stdin abandons
  it — so cl drives it over a FIFO. `thread/start` writes the rollout under
  `sessions/` and `thread/name/set` appends to `session_index.jsonl`, so
  `discover_codex` lists the new thread by name before any turn. A
  `codex resume <id> "<prompt>"` of such a thread fired a project
  `.codex/hooks.json` SessionStart hook on its first turn, with `session_id` set
  to the new id and `source: "resume"`; `thread/start` alone fired nothing.
- **Storage.** `sessions.codex` holds `resume` or `fresh` per session. There is
  no Codex default in the store: the stored default may be `compact-resume`,
  which a Codex session cannot do, so a Codex session without a setting is
  `resume`. `cl mode --codex "Name" fresh|resume|clear`, `cl rotate off
  --codex "Name"` and `cl rotate clear --codex "Name"` are accepted;
  `compact-resume`, `handoff`, `rotate on --codex` and `mode --codex --default`
  are refused with a message.
- **The stop** records the Codex mode on the row (`--no-handoff` makes it
  `resume`, as for Claude; `--require-handoff` does not change a Codex row) and
  says so for a fresh one. Codex rows stay out of the rotation log.
- **Step 3** sets the row's `mode` to `resume` and keeps the old id as
  `fresh_from`, under the same lock `ack_state_row` takes. If the launch that
  follows is refused and the row stays for a later start, that start resumes
  the new thread instead of making another.
- **Undoing a failure.** A new thread that will not be used is archived, so two
  threads never share the name (discovery is newest-wins, and the empty one
  would win). A failed step 3 unarchives the old thread first. Archive and
  unarchive are judged by where the rollout ends up, not only by exit code.
- **Never archive a running thread.** If a local process is resuming the old
  thread, or cl's launch record says one is, the replacement is refused and the
  thread resumed plainly.
- **The bare-tab path** carries the mode and the old id in the tab command
  (`cl --codex "Name" --restart-mode fresh <old-id>`); the tab does steps 1-4.
  A tab that runs after the name has moved on to another thread resumes that
  thread rather than replacing it. Because `cl start` re-arms the lanes before
  its tabs run, archive-before-rearm does not hold here: until the new thread's
  first turn fires SessionStart, the election may still name the old one.
- **`CL_ROTATE`** set to `fresh` or `resume` (or `0`/`off`) applies to a Codex
  session for that stop; a Claude-only mode in it does not change a Codex row.
- **A refused tmux launch after steps 1-3** keeps the row (now on the new id,
  mode `resume`), records the old id in `fresh-history.json` and prints its
  recovery command, as the other failure paths do.

## `cl compact`: steps 2-5 without a stop

`cl compact "Name" ["Name"...]` or `cl compact --all` (every running Claude
session cl knows). It runs the same code as the stop's compact phase
(`compact_phase`, which `do_stop` calls as `compact_phase stop`): the
pre-compact request with its `cl-done` token, the token wait, one `/compact`,
and the boundary or `Compacted` confirmation, for every target in one shared
`CL_COMPACT_TIMEOUT` window. A boundary before `/compact` means it is already
compacted and `/compact` is skipped, as in a stop.

What is different:

- **No stop.** Nothing is saved, retired, killed or rotated; no row and no mode
  changes. The session keeps running.
- **The request says so.** The pointer reads `cl compact: …`, and the request
  says the session will keep running rather than that it is about to be
  restarted. The optional workflow file applies as for a stop.
- **Fallbacks lead nowhere.** No token in time: nothing more is done ("did not
  finish its turn; not compacted"). No boundary after `/compact`: "compaction
  not confirmed", and `/compact` is not typed again — a slow compaction
  retyped would compact its own summary. No pane or no transcript: not
  compacted. Any of these makes the exit non-zero.
- **Targets.** A named session that is not running, or is not known, is
  reported and skipped (non-zero). A Codex session is skipped with a note —
  named, that is non-zero; under `--all` it is only noted. `--all` with no
  running Claude session exits 0. Naming no target, or names and `--all`
  together, is refused.
- **Interrupted** (INT, TERM, HUP), it removes the pre-compact requests this
  run wrote, restores the traps it replaced, and exits 130/143/129, saying how
  many it removed and naming any it could not. A pointer already typed cannot
  be recalled: a session that has read it will still finish its turn and
  reply; it just gets no `/compact`.
- **Which request is "this run's".** Only a file holding a token this run
  issued. A session refused or skipped before a token was issued has no
  request of this run, so nothing is removed for it. Removal renames the file
  to a name only that call knows, checks the token, then deletes it — or puts
  it back if it is not ours (a link, or a no-clobber move), so a newer request
  written in between is never the one deleted. If it cannot be put back, it is
  KEPT under that name, said, and the call fails — unless what is now at the
  path is established to supersede it: a different `cl-done` token, or a
  byte-identical copy. A removal or put-back that fails is reported, and under
  `cl compact` makes the exit non-zero.
- **The report** is one line per target: the path taken and the boundary
  record's `preTokens → postTokens`.
- **No rotation log line.** The log is one row per stop and `cl rotate stats`
  counts its rows as stops; a compaction that stopped nothing does not fit
  that schema, so it is not logged.

## Out of scope here

- Clearing leftover text in an input box before typing. A line appended to
  leftover text shows up as "not arrived whole" and is retyped once; clearing
  it belongs inside the senders if it is ever needed.
