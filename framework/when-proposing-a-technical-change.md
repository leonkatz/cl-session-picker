---
name: when-proposing-a-technical-change
description: Team-impact checklist — maintainability, complexity, documentation, knowledge transfer, on-call, capacity — before recommending a solution, tool, or infrastructure change
type: when
---

# when-proposing-a-technical-change

**Trigger:** before recommending any technical solution, infrastructure change,
or new tooling.

The question is not "does this work" but "can the team live with it."

## Checklist

- [ ] **Maintainability** — can people other than the author maintain it? Does
      it follow patterns the team already knows? Is it documented?
- [ ] **Complexity** — does it introduce a new technology or pattern? What is
      the learning curve? Is the complexity paid for by the benefit?
- [ ] **Documentation** — README updated? Runbook in `{doc-store}` updated or
      needed?
- [ ] **Knowledge transfer** — who else needs to know? Is training needed? Can
      it go into onboarding?
- [ ] **On-call** — what new failure modes does it add? Are alerts in
      `{observability}` configured? Is troubleshooting written down?
- [ ] **Capacity** — who implements, who maintains, and is that the best use of
      their time?

## Present as

```
Team impact:
- Maintainability: [high / medium / low] — [why]
- Learning curve:  [low / medium / high] — [new tech: …]
- Documentation:   [README / runbook / none]
- Training:        [yes / no] — [who]
- On-call:         [new alerts / new failure modes / none]
- Capacity:        [who implements, who maintains]

Recommendation: [proceed / simplify / defer]
```

**Verification:** the assessment appears before a non-trivial solution is
implemented, not after.
