#!/usr/bin/env bash
# Proves the command in framework/when-committing-on-a-personal-branch.md
# detects exactly the "changed in this commit AND on main since divergence"
# case — run: tests/test-branch-sync.sh
#
# The procedure's core is one shell pipeline; prose review cannot tell whether
# it computes the right set, so this fixture does.
set -u

# Hermetic: the fixture must not inherit the developer's git config. With a
# mandatory-signing config and an unreachable signer, the first commit failed,
# `main` was never created, and four of five cases still reported ok because a
# broken repo produced the same empty strings the negative cases expected
# (independent review, 2026-09-01). So: no global/system config, signing off,
# and repository construction fails the run immediately.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false

FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-sync.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }

# The exact command from the procedure, with <main-branch> bound to "main".
both_sides() {
  local merge_base; merge_base=$(git merge-base main HEAD)
  comm -12 <(git diff --name-only "$merge_base" main | sort) <(git diff --cached --name-only | sort)
}

cd "$FIX" || exit 1
setup_failed() { printf 'FIXTURE SETUP FAILED at: %s\n' "$1" >&2; exit 2; }
{ git init -q -b main . && git config user.email t@example.invalid && git config user.name t; } || setup_failed init
printf 'a\n' > shared.txt; printf 'b\n' > main-only.txt; printf 'c\n' > mine-only.txt
{ git add . && git commit -q -m base; } || setup_failed "base commit"

# Diverge: main changes shared.txt and main-only.txt; personal branch stages shared.txt and mine-only.txt.
git checkout -q -b personal || setup_failed "branch personal"
{ git checkout -q main && printf 'a2\n' > shared.txt && printf 'b2\n' > main-only.txt && git commit -q -am "main side"; } || setup_failed "main-side commit"
{ git checkout -q personal && printf 'a3\n' > shared.txt && printf 'c3\n' > mine-only.txt && git add shared.txt mine-only.txt; } || setup_failed "staging on personal"

# Precondition proof — a broken fixture must never look like a passing negative case.
printf 'fixture preconditions\n'
check "main and personal diverged (two commits on main, one shared base)" "2 1" "$(git rev-list --count main) $(git rev-list --count personal)"
check "two files are staged on personal" "mine-only.txt shared.txt" "$(git diff --cached --name-only | sort | tr '\n' ' ' | sed 's/ $//')"

printf 'both-sides detection\n'
check "intersection is exactly the file changed on both sides" "shared.txt" "$(both_sides | tr '\n' ' ' | sed 's/ $//')"
check "a file changed only on main is not reported"            "" "$(both_sides | grep -x main-only.txt)"
check "a file changed only in this commit is not reported"     "" "$(both_sides | grep -x mine-only.txt)"

# The wrong form from the first draft — proves why it was wrong.
printf 'regression: the old three-dot form\n'
old=$(git diff main...HEAD --name-only | sort | tr '\n' ' ' | sed 's/ $//')
check "old 'git diff main...HEAD' lists nothing useful for staged work (staged changes are not in HEAD)" "" "$old"

# One-sided only: unstage shared.txt → nothing should fire.
git restore --staged shared.txt
check "with the shared file unstaged, the check is silent" "" "$(both_sides)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
