---
name: when-running-an-iac-wrapper
description: Safety rules for an infrastructure-as-code wrapper — the target environment is always explicit in automation, and lock overrides are documented and verified first
type: when
---

# when-running-an-iac-wrapper

**Trigger:** any `<iac-tool>` command appears in code, CI configuration, or
documentation.

The failure this guards against: an automated run that applies to *whatever
environment the tool defaulted to* because the target was not named.

## Rules

1. **In automation, the environment is explicit.**
   - ❌ never: `<iac-tool> <auto-approve-flag>` with no target
   - ✅ always: `<iac-tool> <auto-approve-flag> <env-flag> <environment-path>`
2. **Overriding a state lock** (`<force-unlock-command>`):
   - document *why* in `{issue-tracker}` before running it
   - verify nobody else is mid-run against that state
   - in automation, still pass `<env-flag>`
3. **Before every command, ask:**
   - [ ] automation or local? (automation requires `<env-flag>`)
   - [ ] is `<auto-approve-flag>` paired with `<env-flag>`?
   - [ ] if a lock override: is it documented, and is the state idle?

## When a violation is found

```
❌ <iac-tool> safety issue

Issue:           {what is wrong}
Correct command: {fixed version}
Why:             {which rule, and what the wrong form would have done}

Proceed with the corrected version?
```

## Bindings

Your own instructions name `<iac-tool>`, `<auto-approve-flag>`, `<env-flag>`,
`<environment-path>` (the layout of environment definitions), and
`<force-unlock-command>`.

**Verification:** every `<iac-tool>` invocation follows the rules; violations
are corrected before they run.
