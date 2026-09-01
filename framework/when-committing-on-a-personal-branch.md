---
name: when-committing-on-a-personal-branch
description: Before committing on a long-lived personal branch, check whether the files also changed on the main branch and offer to sync first
type: when
---

# when-committing-on-a-personal-branch

**Trigger:** before creating a git commit, when the current branch is a
long-lived personal branch (`<personal-branch>`) that is periodically synced
with `<main-branch>` rather than merged through pull requests.

The failure this guards against: a commit that lands cleanly on
`<personal-branch>` and then conflicts, weeks later, with a change that
`<main-branch>` already carried for the same file.

## Procedure

1. Confirm the branch: `git branch --show-current`.
2. If it is `<personal-branch>`, list the files about to be committed and, for
   each, check whether `<main-branch>` has changed it since the branches
   diverged:
   ```bash
   git diff <main-branch>...HEAD --name-only
   ```
3. If any file changed on both sides:
   ```
   ⚠️ Sync check
   These files have changes on both <personal-branch> and <main-branch>:
   - {file}
   - {file}

   Options:
   1. Bring <main-branch>'s changes in first (recommended)
   2. Commit now and merge by hand later
   3. Show the differences first
   ```
4. Otherwise, commit.

## Bindings

Your own instructions name `<personal-branch>` and `<main-branch>`, and the
sync mechanism you use (cherry-pick, rebase, or merge). Teams that work
through short-lived branches and pull requests do not need this procedure —
the pull request is the sync check.

**Verification:** the check runs before every commit on `<personal-branch>`.
