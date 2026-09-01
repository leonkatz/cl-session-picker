---
name: when-deleting-cloud-resources
description: Describe every resource by name and tags, classify it as target / associated / account infrastructure / unknown, and confirm before deleting anything that is not a clear target
type: when
---

# when-deleting-cloud-resources

**Trigger:** before deleting *any* cloud resource — compute, volumes, storage,
identities and roles, network rules, anything.

The failure this guards against: a name-pattern sweep that takes account
infrastructure, another team's resources, or a recovery artifact along with
the thing being decommissioned.

## Procedure

1. **Describe** the resource: name, every tag, metadata, and what it is
   attached to (policies, instance profiles, rules, references from services).
2. **Present** each one:
   - type and id
   - name
   - all tags — especially `<owner-tag-key>`, `<iac-repo-tag-key>`,
     `<environment-tag-key>`, `<inventory-tag-key>`
   - associations
3. **Classify** each one:
   | Class | Meaning | Action |
   |---|---|---|
   | **Target** | directly the thing being decommissioned | ready to delete |
   | **Associated** | created for the target, but shared or reusable | confirm first |
   | **Account infrastructure** | serves the account, not one workload (audit trail, config recorder, network) | do not delete without explicit approval |
   | **Unknown** | ownership cannot be determined | **do not delete** |
4. **Confirm** explicitly before deleting anything that is not Target.

## Present as

```
Resource deletion review

| Resource | ID | Name / tags | Classification |
|---|---|---|---|
| {type} | {id} | {name}, {owner-tag}: {value} | Target |
| {type} | {id} | {iac-repo-tag}: {value} | Account infrastructure |

Target (N): ready to delete
Associated (N): confirm before deleting
Account infrastructure (N): do not delete without explicit approval
Unknown (N): will not delete

Proceed with Target resources?
```

## Rules

- Never delete everything matching a name pattern without reading tags first.
- Never delete a role or identity without checking `<iac-repo-tag-key>` and
  `<owner-tag-key>`.
- Never delete a resource whose `<iac-repo-tag-key>` points at a repository
  that is not one of `<your-iac-repos>`.
- No tags at all → Unknown.
- An identity referenced by an active account-level service → flag it, do
  not delete.
- State stores for `<iac-tool>` are recovery artifacts → explicit
  confirmation, always.

## Bindings

Your own instructions name the tag keys (`<owner-tag-key>`,
`<iac-repo-tag-key>`, `<environment-tag-key>`, `<inventory-tag-key>`), the
set `<your-iac-repos>`, and `<iac-tool>`. With no tagging convention bound,
*every* resource is Unknown until a person classifies it.

**Verification:** every resource is reviewed by name and tags, and its
classification is shown, before anything is deleted.
