# cl-session-picker

`claude-session` — an interactive picker for resuming named [Claude Code](https://claude.com/claude-code)
and [Codex CLI](https://github.com/openai/codex)
sessions, bound to the `cl` alias.

Auto-discovers every session you've `/renamed` (no registry to maintain — name a
session and it shows up), marks which are live in tmux, and on select attaches or
relaunches it in a persistent tmux session. A "new claude here" entry starts a
fresh session in the current directory. `cl stop` / `cl start` tear down and
rebuild your whole working set, with a rotating state history so a failed restart
never loses the list.

## Install

Standalone, idempotent, re-runnable:

```
git clone https://github.com/leonkatz/cl-session-picker.git
cd cl-session-picker
./install.sh
```

Re-run `./install.sh` after `git pull` to reinstall the new version (the
installer copies the script into your bin dir — it is not symlinked, so the
installed command keeps working even if this repo isn't present).

### What the installer does

1. **Dependencies** — `brew install tmux fzf` if missing. Both are optional; the
   script degrades gracefully (no tmux → launches `claude` directly; no fzf →
   numbered menu instead of the fuzzy picker).
2. **Install** — copies `bin/claude-session` to `~/.local/bin/claude-session`.
3. **tmux settings** — adds to `~/.tmux.conf`: `set -g set-titles on` /
   `set -g set-titles-string "#S"` (terminal title tracks the session name),
   `set -g mouse on` (trackpad/wheel scrolls into scrollback), and
   `set -g history-limit 50000` (larger scrollback buffer).
4. **Shell** — writes the PATH + `cl` alias into a snippet the installer owns
   (`~/.local/share/claude-session/shellrc`) and appends a one-line source
   guard to `~/.zshrc`. If `~/.zshrc` is a **symlink** (a dotfiles manager owns
   it), nothing is appended — add the printed source line to your managed file
   instead. An older inline block is migrated to the guard on rerun.

All edits are sentinel-guarded and back up the prior file, so reruns are no-ops.

### Flags

- `--dry-run` — print actions without executing them
- `--no-deps` — skip the Homebrew dependency install
- `--no-shellrc` — skip `~/.zshrc` edits (PATH + `cl` alias)
- `--no-tmux-conf` — skip `~/.tmux.conf` edits
- `--no-framework` — skip installing `framework/*.md` to `~/.claude/framework`
- `--bin-dir P` — install to `P` instead of `~/.local/bin`

## Uninstall

Reverses the install — removes the binary and the sentinel-guarded blocks it
added to `~/.zshrc` and `~/.tmux.conf` (backing each file up first):

```
./uninstall.sh
```

By default it **leaves your session state** (`~/.config/claude-session/`, i.e.
saved lists + history) and the Homebrew deps (`tmux`/`fzf`/`jq`) in place — those
are your data and general-purpose tools. Pass `--purge-state` to also delete the
session state. Open a new terminal afterward so the `cl` alias stops resolving.

### Uninstall flags

- `--dry-run` — print actions without executing them
- `--no-shellrc` — leave `~/.zshrc` untouched
- `--no-tmux-conf` — leave `~/.tmux.conf` untouched
- `--purge-state` — also delete `~/.config/claude-session` (state + history)
- `--bin-dir P` — look for the binary in `P` instead of `~/.local/bin`

## Usage

- `cl` — open the picker
- `cl <name>` — launch that named session directly (attaches it if already live).
  **This is the primary path** — exact, no picker, immune to fuzzy-match misses
  and to long lists scrolling a session out of view.
- `cl new "Name" [dir|-d]` — create a **fully-named** session in one step (no `/rename`)
- `cl new --codex "Name" [dir|-d]` — start a fresh Codex CLI session (see [Codex CLI sessions](#codex-cli-sessions))
- `cl --list` — print discovered sessions (`--codex` / `--claude` first to filter)
- `cl --codex "Name"` — resume a Codex session when the same name exists for both agents
- `cl stop` — snapshot live sessions, kill them, and close their iTerm tabs (`--keep-tabs` to leave tabs open)
- `cl start` — relaunch every session from the last `stop`
- `cl restore` — restore `state.json` from the newest history snapshot (then `cl start`)

## Creating a new session — `cl new`

`cl new "Session Name"` launches a session that's **named from the first
keystroke** — no `cl` → "new claude here" → `/rename` → exit → re-pick dance. It
passes `claude --name`, which sets the session's title so it shows up correctly in
the terminal, in Claude's own `/resume` picker, and (after its first message) in
`cl`/`cl --list`/`cl start`.

Where it launches:

| Command | Directory |
|---|---|
| `cl new "Name"` | current dir (`$PWD`) — launch where you're standing |
| `cl new "Name" -d` | `$CL_DEFAULT_DIR` (your main repo) |
| `cl new "Name" ~/some/repo` | that explicit dir |

If you run most sessions from one repo, set it once so `-d` lands there from
anywhere:

```
export CL_DEFAULT_DIR="$HOME/path/to/your-repo"   # in ~/.zshrc
```

Run interactively, `cl new` creates **and attaches** the session. Run without a
TTY (from a script, or a Claude Bash call — "spin me up a session called X"), it
creates the session **detached** and prints `attach with: cl "X"`.

> Note: `claude --name` writes the session's title into its transcript on its
> **first message**, so a brand-new, untouched session isn't in `cl --list` yet —
> but `cl "X"` attaches it immediately (it falls back to the live tmux session by
> name), and the title is already correct everywhere else. Send one message and it
> appears in the picker too.

## Codex CLI sessions

If [Codex CLI](https://github.com/openai/codex) is installed, `cl` discovers its
named sessions too — the ones you've `/rename`d inside `codex`, same
no-registry rule as Claude. They appear in the picker and `cl --list` with a
`codex` tag, and `cl <name>` resumes one via `codex resume <id>`.

| Command | What it does |
|---|---|
| `cl --codex --list` / `cl --claude --list` | show only that agent's sessions |
| `cl --codex "Name"` / `cl --claude "Name"` | pick the agent when one name exists for both (`cl "Name"` refuses to guess) |
| `cl new --codex "Name" [dir\|-d]` | start a fresh `codex` in that dir |

**Launch policy.** `cl` adds *no* approval or sandbox flag to Codex — it runs
with whatever `codex` itself is configured to do. To add flags, set
`CL_CODEX_ARGS`; it is appended verbatim to every Codex launch and is treated as
shell syntax, so quote it as you would on the command line:

```
export CL_CODEX_ARGS='--approve-for-me'      # e.g. auto-review approvals
export CL_CODEX_ARGS='-m gpt-5 -s workspace-write'
```

`--remote` isn't supported through `cl`: discovery reads Codex's local session
storage, so the ids it finds only mean something to a local `codex`.

**Naming.** Codex has no launch-time name flag, so `cl new --codex "Name"`
names the tmux session / cmux tab only; the Codex thread itself is unnamed —
and invisible to `cl --list` — until you run `/rename Name` inside it. `cl`
prints that reminder when it launches.

**Live marker.** For Codex, ● means a local `codex resume <id>` process exists —
a reason to refuse launching a second one, not proof the thread is idle or
alive (Codex threads can also run under its app-server daemon or the desktop
app, which `cl` can't see). `cl stop` / `cl start` are Claude-only for now.

**In cmux**, Codex launches via `cmux codex-teams` when that subcommand exists
(probed, not assumed), otherwise plain `codex`. `CL_TEAMS=0` opts out for both
agents.

Discovery reads `~/.codex/session_index.jsonl` and the rollout transcripts
under `~/.codex/sessions/` (`CODEX_HOME` overrides the base dir). Those are
Codex's private files, not an API: if a Codex release moves them, `cl` prints
`unsupported Codex storage layout` rather than silently showing no sessions.
Archived sessions (`codex archive`) are excluded. `tests/test-discover.sh`
exercises all of this against fixtures.

## Framework procedures

`framework/` holds generic operating procedures for an AI coding session — how
to delegate, propose a change, present a decision, disagree, and route what it
writes — as one `when-<activity>.md` file each, shape only, no tool names. The
installer copies them to `~/.claude/framework/` and stops; import the ones you
want from your own `CLAUDE.md`:

```markdown
@~/.claude/framework/when-presenting-a-decision.md
@~/.claude/framework/when-routing-a-communication.md
```

and bind the `{slot}` placeholders (`{issue-tracker}`, `{chat}`, `{notes}`, …)
to your own tools beneath the import. See [`framework/README.md`](framework/README.md).
`--no-framework` skips this step.

## start / stop

`cl stop` / `cl start` tear down and rebuild your whole working set — for a
reboot, or to pick up a new Claude version (a running session keeps the version
it launched with; only a fresh launch upgrades).

- **`cl stop`** writes the live sessions to `~/.config/claude-session/state.json`
  (one record per session: name, session id, cwd), then kills them. Before
  killing a session that looks **mid-task**, it asks `Kill it anyway? [y/N]`;
  answer no and that session is left running while the rest are killed. Re-run
  `cl stop` once it's idle to catch it. Needs `jq`.
  - **Closes the iTerm tab too.** Each tab `cl` opens is tagged with an iTerm
    user variable (`user.clSession`, via an OSC 1337 escape), so `stop` can find
    and close the exact tab of every session it kills — leaving no empty
    "[Process completed]" tabs behind. It never closes the tab you ran `cl stop`
    from, and never touches a session it left running. iTerm-only (other
    terminals can't be scripted this way) and best-effort; pass `--keep-tabs`
    to leave all tabs open.
- **`cl start`** reads the state file and, for each session, reattaches if it's
  already live, else creates the tmux session and resumes the pinned
  conversation by id. Then attach with `tmux attach` (or `tmux -CC attach` in
  iTerm for native tabs).

### State history (recovery)

`cl start` deletes `state.json` once consumed, so a failed relaunch used to lose
the whole list. Now every `cl stop` (and every `cl start`, just before it clears
the file) banks a timestamped copy into `~/.config/claude-session/history/`,
keeping the newest 10. Only valid JSON is archived, so corruption never pollutes
the history. To recover after a bad start or a corrupted file:

```
cl restore        # copy the newest snapshot back to state.json
cl start          # bring the sessions back
```

`cl restore --list` shows every snapshot (newest first) with session count and
age; `cl restore <file>` restores a specific one (a bare filename resolves
against the history dir) in case the newest is bad. Restore archives the current
`state.json` first, so it can never lose the live list, and refuses a snapshot
that isn't valid JSON.

Even without the history, the list is fully reconstructable from your transcripts
(it is just name/id/cwd per named session) — the history simply makes recovery a
one-liner.

### Mid-task detection

Claude's TUI runs on the alternate screen buffer, so `tmux capture-pane` can't
see its output. `stop` instead inspects the pane's process tree: a `caffeinate`
wake-lock child (which `claude` spawns while working) or claude CPU over ~15%
marks the session busy. The signal is intentionally conservative — caffeinate's
timeout lingers a few minutes after work ends — so `stop` errs toward asking
rather than silently killing.

## How discovery works

Each session you `/rename` writes a `custom-title` record into its transcript at
`~/.claude/projects/*/*.jsonl`. `discover()` greps those records for the latest
title per session, skips any whose recorded working directory no longer exists,
and dedupes by name. (An older `agent-name` record exists only for a subset of
sessions, so it is deliberately **not** used — it would hide most named sessions.)

## cmux sidebar

If you use [cmux](https://cmux.com), `cmux/sidebars/sessions.swift` is a custom
sidebar that groups your sessions by real activity (Active / Recent / Idle /
Cold, with live ago-times and last-message previews) instead of cmux's built-in
idle-timer "Needs input" label. See [cmux/sidebars/README.md](cmux/sidebars/README.md)
for install and caveats.

## Requirements

- macOS — the script uses BSD `stat -f %m` for transcript mtimes, and the
  installer uses Homebrew for dependencies.
- [Claude Code](https://claude.com/claude-code) — this resumes its sessions.
- Optional: `tmux` (persistent sessions), `fzf` (fuzzy picker), `jq` (`stop`/`start`/`restore`).

## License

[Apache-2.0](LICENSE) © Leon Katz
