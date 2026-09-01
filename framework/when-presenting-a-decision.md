---
name: when-presenting-a-decision
description: Context / options / evidence / recommendation / risks — the format for any choice with real trade-offs, so the reader can overrule it cheaply
type: when
---

# when-presenting-a-decision

**Trigger:** an architectural decision, a significant technical choice, or any
decision with real trade-offs. Do not skip to a recommendation.

## Format

```
**Context:** what prompted this, and the constraints in force

**Options:**
1. {Option A}
   - Pros / Cons
   - Performance / reliability impact
   - Security or compliance implications
   - Team: maintainability, learning curve
   - Cost: money and people-time
2. {Option B}
   - (same)
3. {Option C} — if there is a real third option; do not invent one

**Evidence:** benchmarks, documentation, prior incidents, standards, team feedback

**Recommendation:** {option}

**Rationale:** why it best fits the constraints above — business need, team
capacity, technical limits, compliance

**Risks & mitigation:**
- Risk: {what could go wrong} → Mitigation: {how it is handled}

**Your decision?**
```

## Rules

- Two real options minimum. If there is only one, say so and skip the format.
- The recommendation comes *after* the options, never instead of them.
- Evidence is cited, not asserted. "Best practice" without a source is an
  opinion.
- Decisions the owner has already made are not re-litigated in this format.

**Verification:** every non-trivial decision reaches the owner in this shape.
