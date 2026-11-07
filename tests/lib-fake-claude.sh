# Sourced by the suites: a Claude stand-in that cl's process-identity check
# (proc_identity / _claude_argv_session) accepts for the honest reason.
#
# cl reads a process's REAL executable image and REAL argv from the kernel, so
# the old stand-ins — `exec -a "claude --resume <sid>" sleep 600`, or a shell
# script named claude — are, correctly, not Claude: their image is sleep or sh.
# This makes a file that IS named claude: a copy of this machine's Python
# interpreter image. Not the launcher on PATH (a framework build's python3
# re-executes a different binary), but the image libproc reports for a running
# interpreter, which then runs as itself under the new name. Nothing in cl is
# told about it: no environment override, no allow-list.
#
#   fake_claude_image <path>      make it; 1 when this machine cannot
#   "<path>" -c "$FAKE_CLAUDE_IDLE" --resume <sid> [more claude args…]
#                                 an idle client of <sid>, by its real argv
#   …-c "$FAKE_CLAUDE_IDLE" --ignore-term …
#                                 the same, ignoring SIGTERM
FAKE_CLAUDE_IDLE='import signal, sys, time
if "--ignore-term" in sys.argv:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(600)'

fake_claude_image() {
  local dest="$1" img
  img=$(python3 -I -c 'import ctypes, os
if os.path.exists("/proc/self/exe"):
    print(os.path.realpath("/proc/self/exe"))
else:
    b = ctypes.create_string_buffer(4096)
    n = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(os.getpid(), b, 4096)
    print(b.value.decode() if n > 0 else "")' 2>/dev/null)
  [ -n "$img" ] && [ -x "$img" ] || return 1
  mkdir -p "$(dirname "$dest")" && cp "$img" "$dest" && chmod +x "$dest" || return 1
  "$dest" -c 'pass' >/dev/null 2>&1
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
