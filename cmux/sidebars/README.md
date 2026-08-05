# cmux custom sidebars

Custom sidebars for [cmux](https://cmux.com) that complement `cl` — they show
the real state of your Claude Code sessions instead of the built-in
"Needs input" label (which fires on a fixed 60-second idle timer, not on an
actual question).

## sessions.swift

Groups every cmux workspace by *when its Claude session last answered*:

- **Active** — answered in the last 10 minutes
- **Recent (< 2h)** — with exact ago-times (`1h 12m`)
- **Idle** — older, sorted most-recent-first
- **Cold** — no agent activity since cmux launched (compact one-line rows)

Each row is click-to-jump and shows the session's last message (two lines).
The clock and ago-labels update live (~1s).

## Install

```bash
mkdir -p ~/.config/cmux/sidebars
cp cmux/sidebars/sessions.swift ~/.config/cmux/sidebars/
cmux sidebar validate sessions
```

Then either:

- `cmux sidebar open sessions` — open as a normal pane tab (drag it into a
  right-hand split and keep it there; recommended), or
- `cmux sidebar select sessions` — swap it into the left sidebar slot, or
- right-click the sidebar toggle button (the panel icon in the title bar,
  just right of the traffic lights) and pick **sessions**.

The file hot-reloads on save, so edits show up immediately.

## Known limitations

- cmux tracks `latestAt` / `latestMessage` in memory per app run — after a
  cmux restart every session reads as **Cold** until it takes its next turn.
- The sidebar DSL cannot see process CPU or detect "ended on a question", so
  Active ≈ "answered very recently", not "currently computing".
- DSL quirk: prefix `!` on a user-defined function call is silently dropped
  by the interpreter — write `f(x) == false` instead of `!f(x)`.
