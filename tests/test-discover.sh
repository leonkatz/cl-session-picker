#!/usr/bin/env bash
# Discovery tests for bin/claude-session — run: tests/test-discover.sh
#
# Builds a throwaway HOME with fixture Claude transcripts and Codex storage,
# then checks what `claude-session --discover` reports. Everything the picker
# knows about a session comes from these private on-disk layouts, so this is
# where a Claude Code / Codex CLI storage change shows up first.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CL="$HERE/../bin/claude-session"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/cl-test.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# --- fixtures ---------------------------------------------------------------
export HOME="$FIX/home"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$HOME/.claude/projects/p1" "$CODEX_HOME/sessions/2026/01/01" "$CODEX_HOME/archived_sessions/2026/01/01"
mkdir -p "$FIX/work" "$FIX/other"

# Claude: two transcripts, one renamed twice (last customTitle wins).
printf '{"cwd":"%s"}\n{"customTitle":"Alpha"}\n{"customTitle":"Alpha Two"}\n' "$FIX/work" > "$HOME/.claude/projects/p1/c-alpha.jsonl"
printf '{"cwd":"%s"}\n{"customTitle":"Shared"}\n' "$FIX/work"                            > "$HOME/.claude/projects/p1/c-shared.jsonl"
printf '{"cwd":"%s"}\n{"customTitle":"Gone"}\n'   "$FIX/nonexistent"                     > "$HOME/.claude/projects/p1/c-gone.jsonl"

# Codex rename index: append-only; last line per id is the current name.
ID_A=01aaaaaa-0000-7000-8000-000000000001   # renamed twice
ID_S=01aaaaaa-0000-7000-8000-000000000002   # same name as a Claude session
ID_X=01aaaaaa-0000-7000-8000-000000000003   # archived: index entry, rollout only in archived_sessions/
ID_G=01aaaaaa-0000-7000-8000-000000000004   # cwd no longer exists
ID_N=01aaaaaa-0000-7000-8000-000000000005   # never named (thread_name empty)
ID_D=01aaaaaa-0000-7000-8000-000000000006   # same name as ID_A, older — newest must win
ID_SHAPE='------------------------------------'  # 36 chars, allowed alphabet, wrong layout — must be dropped
ID_SHAPE2='01aaaaaa0000-7000-8000-00000000000-7'  # 36 hex/dash chars with misplaced dashes — must be dropped
# shellcheck disable=SC2016  # single quotes are the point: the id must stay literal shell syntax
ID_EVIL='x; touch cl-pwned; $(id) *'   # shell syntax, not a UUID — must be dropped at discovery (no slash: it has to exist as a filename)
{
  printf '{"id":"%s","thread_name":"first","updated_at":"2026-01-01T00:00:00Z"}\n' "$ID_A"
  printf '{"id":"%s","thread_name":"Shared","updated_at":"2026-01-01T00:00:01Z"}\n' "$ID_S"
  printf 'this line is not json at all\n'
  printf '{"id":"%s","thread_name":"Archived","updated_at":"2026-01-01T00:00:02Z"}\n' "$ID_X"
  printf '{"id":"%s","thread_name":"Gone codex","updated_at":"2026-01-01T00:00:03Z"}\n' "$ID_G"
  printf '{"id":"%s","thread_name":"","updated_at":"2026-01-01T00:00:04Z"}\n' "$ID_N"
  printf '{"id":"%s","thread_name":"Codex Alpha","updated_at":"2026-01-01T00:00:05Z"}\n' "$ID_A"
  printf '{"id":"%s","thread_name":"Codex Alpha","updated_at":"2026-01-01T00:00:06Z"}\n' "$ID_D"
  printf '{"id":"%s","thread_name":"Evil","updated_at":"2026-01-01T00:00:07Z"}\n' "$ID_EVIL"
  printf '{"id":"%s","thread_name":"Shape","updated_at":"2026-01-01T00:00:08Z"}\n' "$ID_SHAPE"
  printf '{"id":"%s","thread_name":"Shape2","updated_at":"2026-01-01T00:00:09Z"}\n' "$ID_SHAPE2"
  printf '%s' '{"id":"trunc","thread_name":"trunc'   # truncated final line, no newline
} > "$CODEX_HOME/session_index.jsonl"

rollout() { # id dir cwd
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"codex-tui"}}\n{"type":"event"}\n' "$1" "$3" \
    > "$2/rollout-2026-01-01T00-00-00-$1.jsonl"
}
rollout "$ID_A" "$CODEX_HOME/sessions/2026/01/01"          "$FIX/other"
rollout "$ID_S" "$CODEX_HOME/sessions/2026/01/01"          "$FIX/work"
rollout "$ID_X" "$CODEX_HOME/archived_sessions/2026/01/01" "$FIX/work"
rollout "$ID_G" "$CODEX_HOME/sessions/2026/01/01"          "$FIX/nonexistent"
rollout "$ID_N" "$CODEX_HOME/sessions/2026/01/01"          "$FIX/work"
rollout "$ID_D" "$CODEX_HOME/sessions/2026/01/01"          "$FIX/work"
touch -t 202601010000 "$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-$ID_D.jsonl"   # older than ID_A's
rollout "$ID_EVIL" "$CODEX_HOME/sessions/2026/01/01"       "$FIX/work"   # a matching rollout exists — validation alone must stop it
rollout "$ID_SHAPE" "$CODEX_HOME/sessions/2026/01/01"      "$FIX/work"
rollout "$ID_SHAPE2" "$CODEX_HOME/sessions/2026/01/01"     "$FIX/work"
# Claude: a transcript whose basename is shell syntax — must be dropped too
printf '{"cwd":"%s"}\n{"customTitle":"Evil Claude"}\n' "$FIX/work" > "$HOME/.claude/projects/p1/c; touch cl-pwned; \$(id).jsonl"

# --- discovery --------------------------------------------------------------
printf 'discover\n'
out="$("$CL" --discover 2>"$FIX/stderr")"
names_for() { printf '%s\n' "$out" | awk -F'\t' -v a="$1" '$5==a{print $1}' | sort | tr '\n' '|'; }

check "claude: last customTitle wins, missing cwd dropped" "Alpha Two|Shared|" "$(names_for claude)"
check "codex: last rename wins; archived, missing-cwd, unnamed, malformed all excluded" "Codex Alpha|Shared|" "$(names_for codex)"
check "codex: an id not laid out as a UUID (8-4-4-4-12 hex) is dropped even when its rollout exists" "" "$(printf '%s\n' "$out" | grep -E "^Shape")"
check "codex: two sessions sharing a name → newest wins" "$ID_A" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="Codex Alpha"{print $2}')"
check "ids that are shell syntax never reach the row set" "" "$(printf '%s\n' "$out" | grep -E ';|\$\(|\*' )"
check "…and neither evil fixture leaked in by name" "" "$(printf '%s\n' "$out" | grep -c "Evil" | grep -vx 0)"
check "…and nothing was executed" "" "$(ls "$PWD/cl-pwned" "$HOME/cl-pwned" 2>/dev/null)"
check "fixture sanity: both evil files exist on disk" "2" "$(ls "$HOME/.claude/projects/p1/"*"cl-pwned"* "$CODEX_HOME/sessions/2026/01/01/"*"cl-pwned"* 2>/dev/null | wc -l | tr -d ' ')"
check "codex: cwd comes from the rollout session_meta" "$FIX/other" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="Codex Alpha"{print $3}')"
check "codex: sid is the rollout uuid" "$ID_A" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="Codex Alpha"{print $2}')"
check "every row has exactly five fields" "" "$(printf '%s\n' "$out" | awk -F'\t' 'NF!=5')"
check "no diagnostics on a recognised layout" "" "$(cat "$FIX/stderr")"

# --- direct launch refuses an ambiguous name --------------------------------
printf 'ambiguity\n'
err="$("$CL" Shared 2>&1 >/dev/null)"; rc=$?
check "cl <name> held by both agents exits 1" "1" "$rc"
case "$err" in *"more than one agent"*) ok "…and says so" ;; *) bad "…and says so" "$err" ;; esac

# --- unsupported layout is loud, not silent ---------------------------------
printf 'layout drift\n'
rm -rf "$CODEX_HOME/sessions"
out="$("$CL" --discover 2>"$FIX/stderr2")"; err="$(cat "$FIX/stderr2")"
case "$err" in *"unsupported Codex storage layout"*) ok "index without sessions/ prints a diagnostic" ;; *) bad "index without sessions/ prints a diagnostic" "$err" ;; esac
check "…and Claude discovery still works" "Alpha Two|Shared|" "$(names_for claude)"

rm -f "$CODEX_HOME/session_index.jsonl"
check "no Codex storage at all is silent" "" "$("$CL" --discover 2>&1 >/dev/null)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
