#!/bin/sh
# Sourced by the hooks that read the network, after lib.sh.

# hook_bounded SECONDS COMMAND...: a network read with a bound of its own,
# well inside the hook's limit (HOOK_NET_SECONDS, default 4 of the 10 a hook
# has). When the bound is hit the command is stopped, nothing is printed, and
# a line says so in the project's .scratch/hooks/timing.log; the caller then
# decides from what it has (a cached reading, or no reading and no refusal).
# Without a timeout command the read is made as it was, unbounded.
hook_bounded() {
  hb_s=$1; shift
  command -v timeout >/dev/null 2>&1 || { "$@"; return $?; }
  timeout "$hb_s" "$@"
  hb_rc=$?
  if [ "$hb_rc" -eq 124 ] && [ "${HOOK_LOG:-1}" != 0 ]; then
    hb_root=${CLAUDE_PROJECT_DIR:-.}
    if [ -d "$hb_root/.scratch/hooks" ] || mkdir -p "$hb_root/.scratch/hooks" 2>/dev/null; then
      printf 'bound\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0" .sh)" "$hb_s" >> "$hb_root/.scratch/hooks/timing.log" 2>/dev/null || true
    fi
  fi
  return "$hb_rc"
}
