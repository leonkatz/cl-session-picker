---
name: when-routing-a-communication
description: Decide where a piece of information goes by the properties of the channel it needs — durable or ephemeral, official or personal, audited or not, individual or shared — then bind to whatever channels you actually have
type: when
---

# when-routing-a-communication

**Trigger:** something needs to be recorded, documented, or communicated.

The procedure is generic; the channels are yours. Route by **properties**, then
bind each property set to a real channel in your own instantiation.

## Channel properties

Every channel you have can be described on four axes:

| Axis | One end | Other end |
|---|---|---|
| Durability | ephemeral — gone in a day | durable — findable in a year |
| Authority | personal — yours alone | official — the record of record |
| Audit | unaudited | audited — someone may have to prove it later |
| Audience | individual | shared — the team, or a stranger later |

## The decision tree

Ask, in order:

1. **Must someone be able to prove this later?** (compliance, security,
   incident) → durable + official + audited → `{issue-tracker}` for the
   tracking record, `{doc-store}` for the write-up.
2. **Is it a procedure someone else will have to run?** → durable + shared →
   `{doc-store}` (runbook).
3. **Is it a decision a future person will need to understand?** → durable +
   shared → `{doc-store}` or the repo's `docs/`, plus the commit message for the
   *why*.
4. **Is it context for the code itself?** → durable + shared, next to the code
   → `CLAUDE.md`, README, comments explaining *why*.
5. **Is it a task the team needs to see?** → durable + shared →
   `{issue-tracker}` (or the team's tracked task list).
6. **Is it a task only you will ever do?** → durable + personal → `{notes}`.
7. **Does it matter for an hour and never again?** → ephemeral → `{chat}`.

Anything that reaches the bottom of the tree unrouted goes to `{notes}` with a
date — a note you can find beats a message you can't.

## Where the standard places live

| Content | Home |
|---|---|
| Quick start, setup, common operations | `README.md` |
| AI context, repo-specific patterns | `CLAUDE.md` |
| Detailed guides, architecture, decisions | `docs/` |
| Runbooks, team process, cross-team docs | `{doc-store}` |
| Official incident / change tracking | `{issue-tracker}` |
| What changed and why | commit messages |

## Binding

Below the import of this file, your own instructions carry a table like:

```
| slot | bound to |
|---|---|
| {issue-tracker} | … |
| {doc-store}     | … |
| {chat}          | … |
| {notes}         | … |
```

Unbound slots degrade: no `{issue-tracker}` → the team task list; no
`{doc-store}` → `docs/` in the repo; no `{chat}` → say it in the session and
write it to `{notes}`.

**Verification:** information lands where its properties say, not where it was
convenient to type.
