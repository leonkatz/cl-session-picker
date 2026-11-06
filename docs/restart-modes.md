# Restart modes — design (not yet built)

Status: proposal for review. Nothing here is implemented yet.

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
   and the number of `compact_boundary` records in it now.
2. **Pre-compact prompt (PASS 2).** Optional, from
   `~/.config/claude-session/precompact-prompt.txt`; nothing by default, because
   what a session should write down is a workflow and belongs to the user (for
   example "update your session board"). Like the handoff request, the full
   text goes into `<store>/<name>.precompact`, a short pointer is typed, and the
   request ends by asking for an exact reply token, `cl-done:<nonce>`, as the
   last thing the session writes.
3. **Wait for the token**, in parallel across sessions: an assistant record
   after the mark containing `cl-done:<nonce>`.
4. **Type `/compact`**, only once the token has arrived, and only if the session
   is not busy. It is never typed twice: a queued second `/compact` would
   compact the summary again.
5. **Wait for the compaction**, in parallel: the boundary count going above its
   baseline. This is the confirmation for the `/compact` line; the delivery
   check cannot see a slash command, and does not need to.
6. **Stop it.** A session confirmed compacted is retired without the
   "looks mid-task, kill it anyway?" prompt. Its leftover helper process
   otherwise makes every compacted session look busy.

On `cl start` the row's `mode` is `compact-resume`: resume with a first prompt
passed as an argument, never typed (from `resume-after-compact-prompt.txt`; a
one-line built-in default says it was restarted and should carry on). If the
agent exits within a few seconds of launch, which is how a failed resume looks,
and a handoff exists, fall back to a fresh session from it.

### Timing

A compaction takes minutes, not seconds, so it does not share the handoff
window. `CL_COMPACT_TIMEOUT` (default 300s) covers steps 3-5 for all sessions at
once. A session that misses it falls back to `handoff` within the remaining
`CL_HANDOFF_BUDGET`; if that is spent too, it resumes as-is and the log says so.

### Fallbacks

| what went wrong | what happens |
|---|---|
| no `cl-done` token in time | skip `/compact`; fall back to `handoff` |
| no boundary in time | fall back to `handoff` |
| session busy throughout | queue nothing further; fall back to `handoff` |
| resume fails at start | fresh session from a handoff if one exists; otherwise report |
| `--no-handoff` | no fallback handoff; resume as-is |

Each stop logs one line per session: the mode asked, the path taken, why, and
the context size before and after. It goes in the existing rotation log, with
new columns.

## fresh, for Codex

The hard part is the lane watcher. `discover_codex` and `coord-rearm` only see
NAMED threads, and the election picks the newest named thread in the repo, so
an unnamed new thread is invisible and the old one keeps the lane. So `fresh`
for Codex must:

1. archive the old thread, so discovery no longer lists it;
2. start the new thread with a short first prompt passed as an argument, so a
   turn fires the repo's SessionStart hook;
3. name it with the old name through `codex app-server` (`thread/name/set`),
   check the name took, and report if it did not;
4. re-arm the lane, which then elects the new, named thread;
5. stamp the new tmux session with the new thread id, so the next `cl stop` owns
   it.

The lane's unanswered notes are re-offered to the new thread by the watcher's
own re-send.

## Out of scope here

- `cl compact [<session>|--all]`: steps 2-5 without a stop. It reuses
  everything above and comes next.
- Clearing leftover text in an input box before typing. A line appended to
  leftover text shows up as "not arrived whole" and is retyped once; clearing
  it belongs inside the senders if it is ever needed.
