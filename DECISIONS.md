# Decisions

Form-factor choices that could have gone another way. Each entry records what
was chosen, what it forecloses, and what would reverse it — so a later change
is a deliberate reversal, not an accident.

## 2026-08-28 — Framework procedures ship as several `when-*.md` files, installed by copy, never wired into CLAUDE.md

**Chose:** `framework/` holds one procedure per file with flat `type: when`
frontmatter. `install.sh` copies them to `~/.claude/framework/` and prints the
`@~/.claude/framework/<file>` import line; it does not edit `~/.claude/CLAUDE.md`.

**Forecloses:** a one-shot "install and it just applies" experience — the user
adds the imports themselves.

**Reverses by:** concatenating the files into one, or adding a sentinel-guarded
import block to CLAUDE.md the way the shell rc is handled.

**Why several files:** a memory tool that indexes `when-<activity>.md` can absorb
them with a move, not a rewrite. **Why no CLAUDE.md edit:** that file is the
user's instantiation — their channels, their names. An installer that writes
into it is writing content, and the repo's rule is that installers write
scaffolding only. **Why copy:** same as the binary — the installed layer must
survive the repo not being present.
