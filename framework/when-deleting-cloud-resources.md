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
3. **Assess** each one on four independent dimensions — a resource can be a
   direct target *and* shared *and* a recovery artifact at the same time:

   | Dimension | Values |
   |---|---|
   | **Scope** | in scope of this decommission / out of scope |
   | **Ownership evidence** | authoritative (tags, `<iac-tool>` state, inventory, provider metadata all agree) / weak / none |
   | **Sharing** | dedicated to the target / shared with other workloads / account-level (audit trail, config recorder, network) |
   | **Recoverability** | recreatable / a recovery artifact (state stores, backups, snapshots, keys) |

4. **Decide** by precedence — any protected dimension blocks automatic
   deletion, even for a direct target:
   - ownership evidence *none* → **do not delete** ("Unknown")
   - recovery artifact, or account-level → **explicit approval, named resource by resource**
   - shared → **confirm first**, and say what else uses it
   - in scope, dedicated, recreatable, authoritative ownership → **ready to delete**
   - out of scope → not touched, whatever else is true

## Present as

```
Resource deletion review

| Resource | ID | Name / tags | Scope | Ownership | Sharing | Recoverable | Decision |
|---|---|---|---|---|---|---|---|
| {type} | {id} | {name}, {owner-tag}: {value} | in | authoritative | dedicated | yes | ready |
| {type} | {id} | {iac-repo-tag}: {value} | in | authoritative | account-level | yes | approval |
| {type} | {id} | (no evidence) | ? | none | ? | ? | will not delete |

Ready (N) · Confirm first (N) · Explicit approval (N) · Will not delete (N)

Proceed with Target resources?
```

## Rules

- Never delete everything matching a name pattern without reading tags first.
- Never delete a role or identity without checking `<iac-repo-tag-key>` and
  `<owner-tag-key>`.
- Never delete a resource whose `<iac-repo-tag-key>` points at a repository
  that is not one of `<your-iac-repos>`.
- No authoritative ownership evidence — not tags, not `<iac-tool>` state, not
  the inventory, not provider metadata — → Unknown. Tags are one source of
  evidence, not the only one.
- An identity referenced by an active account-level service → flag it, do
  not delete.
- State stores for `<iac-tool>` are recovery artifacts → explicit
  confirmation, always.

## Bindings

Your own instructions name the tag keys (`<owner-tag-key>`,
`<iac-repo-tag-key>`, `<environment-tag-key>`, `<inventory-tag-key>`), the
set `<your-iac-repos>`, and `<iac-tool>`. With no tagging convention bound,
*every* resource is Unknown until a person classifies it.

**Verification:** every resource is reviewed by name and evidence, all four
dimensions are shown, and nothing with a protected dimension is deleted
without the named approval.
