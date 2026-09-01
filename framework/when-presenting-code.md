---
name: when-presenting-code
description: Standards, error handling, security, performance, documentation, and team-impact checks that pass before any code is shown, with the summary shown alongside it
type: when
---

# when-presenting-code

**Trigger:** before presenting code that is meant to be **kept** — a change
to a repository, a script someone will run again, a snippet that will be
pasted into production. Not for throwaway illustrations, one-liners in an
explanation, or code the reader asked to see *as it is*.

## Checklist

- [ ] **Standards** — the language's standard from `<coding-standards-source>`
      was consulted; non-obvious choices cite the section; descriptive names;
      type annotations where the language and the codebase's convention use
      them (a dynamically typed idiom is not a failure).
- [ ] **Error handling** — explicit, no silent failures; the exceptions caught
      are the ones the code can actually handle; a catch-all is acceptable only
      at a boundary that logs and re-raises or fails the operation visibly;
      messages say what failed and where.
- [ ] **Security** — the infrastructure checklist
      (`when-presenting-infrastructure-code`) passed where it applies; input
      is validated; nothing new is exposed.
- [ ] **Performance** — no N+1 queries; no nested loops over large data where
      a set or generator would do; data structures fit the access pattern.
      *If the code serves a system with an `<availability-target>`*, its impact
      on that target is considered.
- [ ] **Documentation** — comments explain *why*, not what; docstrings on
      public functions where the language convention expects them.
- [ ] **Team** — impact assessed (`when-proposing-a-technical-change`) for
      anything non-trivial; maintainable by people other than the author;
      follows the patterns already in the codebase.

## If any item fails

1. Fix before presenting.
2. If it cannot be fixed, say which item and why, and get approval.

## Present as

The code, followed by the checklist summary — **only the items that were
waived or that failed and were fixed**, one line each with the reason. An
all-pass checklist is not reported; silence means it passed.

## Bindings

Your own instructions name `<coding-standards-source>` (a skill, a document,
a linter config) and `<availability-target>` if you have one. Unbound, the
standards item reduces to the language's mainstream style guide.

**Verification:** every item passed or explicitly waived; the summary is
shown with the code, not implied.
