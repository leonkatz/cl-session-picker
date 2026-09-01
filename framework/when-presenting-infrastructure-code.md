---
name: when-presenting-infrastructure-code
description: Security checklist — credentials, host hardening, least privilege, input validation, audit trail, encryption — that must pass before any infrastructure code is shown
type: when
---

# when-presenting-infrastructure-code

**Trigger:** before presenting *any* infrastructure code — `<iac-tool>`
modules, image builds, configuration management, scripts that touch cloud
resources.

Every item is checked against the code as written, not as intended.

## Checklist

- [ ] **Credentials** — no hardcoded credentials, tokens, or keys; secrets are
      read from `<secrets-store>` at runtime; nothing sensitive in variables
      files or state.
- [ ] **Host hardening** (when compute is created) — the provider's
      instance-hardening controls are set *explicitly*, not left to defaults
      (`<host-hardening-setting>` — e.g. a metadata-service token requirement).
- [ ] **Least privilege** — roles and policies grant only what the workload
      uses; network rules are minimal, and any open ingress (`0.0.0.0/0` or
      equivalent) is justified in a comment.
- [ ] **Input validation** — user-supplied values are validated; no command,
      query, or path built from raw input.
- [ ] **Audit trail** (when `<compliance-regime>` applies) — the change is
      tracked in `{issue-tracker}`; state is locked by `<iac-tool>` so two
      applies cannot race.
- [ ] **Encryption** — data at rest encrypted (volumes, buckets, databases);
      data in transit over TLS.

## If any item fails

1. Fix it before presenting the code.
2. If it cannot be fixed here, say which item, why, and get explicit approval
   to present it anyway.

## Bindings

Your own instructions fill in: `<iac-tool>`, `<secrets-store>`,
`<host-hardening-setting>`, `<compliance-regime>`, and the `{issue-tracker}`
slot. With no `<compliance-regime>` bound, the audit-trail item reduces to
"the change is in source control with a message that says why."

**Verification:** every item passed (or explicitly waived) before the code is
shown.
