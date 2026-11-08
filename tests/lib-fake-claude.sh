# Sourced by the suites: Claude stand-ins that cl's process-identity check
# (proc_identity / _claude_argv_session) accepts for the honest reason, and the
# registry entry that ties a process to a session the way Claude Code does.
#
# cl reads a process's REAL executable image and REAL argv from the kernel, so
# the old stand-ins — `exec -a "claude --resume <sid>" sleep 600`, or a shell
# script named claude — are, correctly, not Claude: their image is sleep or sh.
#
#   fake_claude_bin <path>    compile a stand-in executable at <path> (name it
#                             claude, or put it at …/claude/versions/<ver>, or
#                             name it node). It ignores its arguments and
#                             sleeps; with an --ignore-term argument it also
#                             ignores SIGTERM. Built with cc, because a copied
#                             system or framework binary can be killed on
#                             launch by code signing. Returns 1 without cc.
#   "<path>" --resume <sid> [more claude args…]
#                             an idle client of <sid>, by its real argv
#   reg_claude <dir> <pid> <sid>
#                             Claude Code's registry entry for a process
#
# Nothing in cl is told about any of this: no environment override, no
# allow-list. A process the suites need to BEHAVE (the Python simulated agent)
# is tied through the registry instead, which cl validates in production.

fake_claude_bin() {
  local dest="$1" src
  command -v cc >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$dest")" || return 1
  src="$dest.c"
  cat > "$src" <<'CEOF'
#include <signal.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; i++)
    if (strcmp(argv[i], "--ignore-term") == 0) signal(SIGTERM, SIG_IGN);
  sleep(600);
  return 0;
}
CEOF
  cc -o "$dest" "$src" 2>/dev/null || { rm -f "$src"; return 1; }
  rm -f "$src"
}

# need_fake_claude <path>: fake_claude_bin, or refuse the whole suite clearly.
need_fake_claude() {
  fake_claude_bin "$1" && return 0
  printf 'FIXTURE SETUP FAILED: a Claude stand-in executable is built with cc (Xcode command line tools); %s\n' \
    "$(command -v cc >/dev/null 2>&1 && echo 'cc could not build it' || echo 'cc is not installed')" >&2
  exit 2
}

# reg_claude <sessions-dir> <pid> <sid>: Claude Code's own registry entry for a
# process, exactly as it writes one — {pid, sessionId, procStart} with the
# start time as `ps -o lstart` reads it in UTC — so cl's production check of
# all three (claude_registry_pid) is what accepts it.
reg_claude() {
  local start
  start=$(TZ=UTC ps -p "$2" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')
  [ -n "$start" ] || return 1
  mkdir -p "$1" && printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}\n' "$2" "$3" "$start" > "$1/$2.json"
}
