# framework — operating procedures for an AI coding session, shape only

These files are the **generic layer** of a session's operating instructions: the
*shape* of how a session should delegate, propose changes, present decisions,
disagree, and route what it writes. They contain no employer, no team, and no
private tool inventory — a well-known product name appears only as an example
of a slot — so every line is meant to be true for someone who is not you and
works somewhere else.

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

That rule cuts the other way for the installed copies: **`~/.claude/framework/`
is package-managed.** Re-running the installer replaces those files (backing up
any that differ first, `*.bak-<timestamp>`), and the uninstaller removes only
files that still match what was shipped — an edited one is left alone. Don't
customise by editing the installed copy; customise in your own `CLAUDE.md`
beneath the `@import`, where nothing will ever overwrite it.

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

## Placeholders — three kinds, don't conflate them

1. **Capability slots** — `{issue-tracker}` · `{doc-store}` · `{chat}` ·
   `{secrets}` · `{observability}` · `{source-control}` · `{calendar}` ·
   `{notes}`. Exactly these eight. Each names a *kind of tool* you may or may
   not have; you bind it to whatever fills that role, or leave it unbound and
   the procedure degrades as documented. Most people bind three or four.
2. **Shape slots** — angle brackets, e.g. `<iac-tool>`, `<main-branch>`,
   `<owner-tag-key>`. A tool name, flag, path, policy, or value that a
   procedure cannot be written without. Bound in the same table as capability
   slots. Some are plain names; some are configuration or policy (a compliance
   regime, a set of repositories) — the procedure says which when it matters.
   A shape slot is a substitution; it cannot make a procedure apply to a tool
   that lacks the *behaviour* the procedure assumes — those procedures state
   their applicability up front, and you omit them when it doesn't hold.
3. **Template fields** — `{file}`, `{option}`, `{why}`, `{what could go wrong}`
   inside a fenced output block. These are what the session fills in when it
   *produces* the output. They are not bound and not slots; they only ever
   appear inside a ```` ``` ```` block.


## Files

| File | Trigger |
|---|---|
| `when-delegating-work.md` | a task lands that someone has to do |
| `when-proposing-a-technical-change.md` | before recommending a solution, tool, or infrastructure change |
| `when-presenting-a-decision.md` | any choice with real trade-offs |
| `when-disagreeing.md` | a statement conflicts with evidence or a standard |
| `when-routing-a-communication.md` | something needs to be recorded, documented, or said |
| `when-presenting-infrastructure-code.md` | before showing infrastructure code — security checklist |
| `when-running-an-iac-wrapper.md` | an infrastructure-as-code command appears anywhere |
| `when-committing-on-a-personal-branch.md` | committing on a long-lived personal branch |
| `when-presenting-code.md` | before showing any code |
| `when-deleting-cloud-resources.md` | before deleting any cloud resource |
