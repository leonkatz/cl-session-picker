---
name: when-committing-on-a-personal-branch
description: Before committing on a long-lived personal branch, find the files that changed on BOTH the main branch and in this commit, and offer to sync first
type: when
---

# when-committing-on-a-personal-branch

**Trigger:** before creating a git commit, when the current branch is a
long-lived personal branch (`<personal-branch>`) that is periodically synced
with `<main-branch>` rather than merged through pull requests.

**Applies only** to that workflow. Teams working through short-lived branches
and pull requests should omit this procedure — the pull request is the sync
check.

The failure this guards against: a commit that lands cleanly on
`<personal-branch>` and then conflicts, weeks later, with a change that
`<main-branch>` already carried for the same file.

## Procedure

"Changed on both sides" means: **the file is in this commit, and
`<main-branch>` has also changed it since the two branches diverged.** Neither
side alone is a conflict.

1. Confirm the branch: `git branch --show-current`. Stop here unless it is
   `<personal-branch>`.
2. Find the point where the branches diverged, the files `<main-branch>` has
   changed since then, and the files about to be committed — then intersect:
   ```bash
   merge_base=$(git merge-base <main-branch> HEAD)
   comm -12 \
     <(git diff --name-only "$merge_base" <main-branch> | sort) \
     <(git diff --cached --name-only | sort)
   ```
   (`--cached` is the staged set. If you commit with `-a`, use
   `git diff --name-only HEAD` for the second list instead. Untracked files
   cannot be on both sides and are not part of the check.)
3. If the intersection is non-empty:
   ```
   ⚠️ Sync check
   These files are in this commit AND have changed on <main-branch> since
   the branches diverged:
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
sync mechanism you use (cherry-pick, rebase, or merge).

**Verification:** the check runs before every commit on `<personal-branch>`,
and `tests/test-branch-sync.sh` in the repo that ships this file proves the
command detects a both-sides change and stays silent on a one-sided one.
