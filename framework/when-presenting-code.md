---
name: when-presenting-code
description: Standards, error handling, security, performance, documentation, and team-impact checks that pass before any code is shown, with the summary shown alongside it
type: when
---

# when-presenting-code

**Trigger:** before presenting *any* code.

## Checklist

- [ ] **Standards** — the language's standard from `<coding-standards-source>`
      was consulted; non-obvious choices cite the section; type annotations
      present where the language supports them; descriptive names.
- [ ] **Error handling** — explicit, no silent failures; specific exceptions,
      never a bare catch-all; messages say what failed and where; recovery is
      appropriate to the failure.
- [ ] **Security** — the infrastructure checklist
      (`when-presenting-infrastructure-code`) passed where it applies; input
      is validated; nothing new is exposed.
- [ ] **Performance** — no N+1 queries; no nested loops over large data where
      a set or generator would do; data structures fit the access pattern;
      impact on `<availability-target>` considered.
- [ ] **Documentation** — comments explain *why*, not what; docstrings on
      public functions where the language convention expects them.
- [ ] **Team** — impact assessed (`when-proposing-a-technical-change`) for
      anything non-trivial; maintainable by people other than the author;
      follows the patterns already in the codebase.

## If any item fails

1. Fix before presenting.
2. If it cannot be fixed, say which item and why, and get approval.

## Present as

The code, followed by a one-line-per-item summary of the checklist —
pass, waived (with reason), or not applicable.

## Bindings

Your own instructions name `<coding-standards-source>` (a skill, a document,
a linter config) and `<availability-target>` if you have one. Unbound, the
standards item reduces to the language's mainstream style guide.

**Verification:** every item passed or explicitly waived; the summary is
shown with the code, not implied.
