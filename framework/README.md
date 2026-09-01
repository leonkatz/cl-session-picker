# framework — operating procedures for an AI coding session, shape only

These files are the **generic layer** of a session's operating instructions: the
*shape* of how a session should delegate, propose changes, present decisions,
disagree, and route what it writes. They contain no employer, no team, no tool
inventory — every line is meant to be true for someone who is not you and works
somewhere else.

They are written so a memory tool can index them as-is: flat `type:`
frontmatter, one procedure per file, named `when-<activity>.md`. Adopting such a
tool later is a file move, not a rewrite.

## Three layers

| Layer | Where it lives | Example |
|---|---|---|
| **Framework** (this directory) | this public repo → installed to `~/.claude/framework/` | *that* channels have properties, and the routing procedure over those properties |
| **Instantiation** | your private dotfiles / config repo | *which* channels you have: `issue-tracker` = Jira, `chat` = Slack, … |
| **Live state** | your notes app, inboxes, boards | the messages, the tasks, the decisions themselves |

The installer copies this directory and stops. It never edits your `CLAUDE.md`
and never writes into the live-state layer — **installers write scaffolding,
never content.** A tool that regenerates a file a person has edited destroys
exactly the most valuable edit in it.

## Using them

Claude Code resolves `@path` imports inside any `CLAUDE.md` / `CLAUDE.local.md`.
After `./install.sh`, add the procedures you want to your own file:

```markdown
@~/.claude/framework/when-presenting-a-decision.md
@~/.claude/framework/when-disagreeing.md
@~/.claude/framework/when-routing-a-communication.md
```

Then write the instantiation beneath the import — a short table binding each
`{slot}` placeholder to the tool you actually have. Slots you don't have stay
unbound; the procedures are written to degrade to "write it down where you keep
notes" rather than break.

## Capability slots

Every placeholder in these files is one of:

`{issue-tracker}` · `{doc-store}` · `{chat}` · `{secrets}` · `{observability}`
· `{source-control}` · `{calendar}` · `{notes}`

Most people bind three or four of the eight.

## Files

| File | Trigger |
|---|---|
| `when-delegating-work.md` | a task lands that someone has to do |
| `when-proposing-a-technical-change.md` | before recommending a solution, tool, or infrastructure change |
| `when-presenting-a-decision.md` | any choice with real trade-offs |
| `when-disagreeing.md` | a statement conflicts with evidence or a standard |
| `when-routing-a-communication.md` | something needs to be recorded, documented, or said |
