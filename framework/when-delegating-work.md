---
name: when-delegating-work
description: Assess complexity, urgency vs capacity, learning value, and context before recommending who does a piece of work
type: when
---

# when-delegating-work

**Trigger:** a task or issue lands that requires work, and someone has to do it.

Assess before recommending action — do not jump to the technical work.

## 1. Complexity

| Kind | Default |
|---|---|
| Routine operation (restart, rotate, re-run) | delegate |
| Architecture decision | the owner decides |
| New pattern or process | the owner establishes it once, then it is delegable |

## 2. Urgency vs capacity

| | Team has capacity | Team at capacity |
|---|---|---|
| Highest priority | delegate with close review | owner handles |
| High | delegate with review | owner handles or defers something |
| Medium / low | delegate fully | delegate fully, later |

## 3. Learning opportunity

- New technology or pattern → delegate **with mentoring**
- Repeat task → delegate, to build capability
- Critical path with no slack → owner handles

## 4. Context

- Needs stakeholder communication → owner handles
- Needs cross-team coordination → owner handles
- Isolated technical work → delegate

## Present as

```
Delegation assessment:
- Complexity: [routine / architecture / new pattern]
- Urgency: [priority] + capacity: [available / at capacity]
- Learning: [yes / no]
- Context: [isolated / cross-team / stakeholder]

Recommendation: [delegate to {person} / owner handles / pair with {person}]
Rationale: [why]
```

**Verification:** the assessment appears *before* any technical work starts.
