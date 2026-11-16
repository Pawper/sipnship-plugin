#!/bin/sh
# A whole part of the suite is run one at a time on a machine, and never
# beside a runner's job. The machine starts about ninety shells a second
# however many ask, so every run beside another slows all of them: a part
# that takes five minutes alone took forty with others running. Sourced by
# tests/run.sh; CI's own runs (GITHUB_ACTIONS set) never take a turn.
#
# The turn is a folder every checkout and worktree on the machine shares
# (SUITE_TURN_DIR, by default under the home folder); making it is the
# atomic take. A turn left by a run that died is taken over once it is older
# than the part's own bound (SUITE_TURN_BOUND, seconds, by default 1200).

turn_dir() { printf '%s\n' "${SUITE_TURN_DIR:-${HOME:-/tmp}/.sipnship-suite-turn}"; }

# turn_stale STARTED NOW BOUND: yes when a turn taken at STARTED (epoch
# seconds) is older than BOUND, or its start cannot be read.
turn_stale() {
  case "$1" in ''|*[!0-9]*) echo yes; return 0 ;; esac
  [ $(( $2 - $1 )) -gt "$3" ] && echo yes || echo no
}

# turn_busy_line HOLDER_PID STARTED: the one line a refused run prints.
turn_busy_line() {
  printf 'Another whole part of the suite is running on this machine (pid %s, started %s); two side by side slow both. Wait for it, push and read the checks, or run the one block that covers your change: sh plugin/tests/run.sh --block NAME.\n' "$1" "$2"
}

# turn_runner_line: the line a run prints when a runner job is working.
turn_runner_line() {
  printf 'A runner job is working on this machine, and a whole part beside it slows both. Push and read the checks, or run the one block that covers your change: sh plugin/tests/run.sh --block NAME.\n'
}

# turn_runner_busy: success while a runner job works on this machine
# (SUITE_RUNNER_BUSY=yes or no stands in for the look, for tests).
turn_runner_busy() {
  case "${SUITE_RUNNER_BUSY:-}" in yes) return 0 ;; no) return 1 ;; esac
  if command -v tasklist >/dev/null 2>&1; then
    tasklist 2>/dev/null | grep -qi 'Runner\.Worker'
  elif command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'Runner\.Worker' >/dev/null 2>&1
  else
    return 1
  fi
}

# turn_take: take the machine's turn for this run. Prints the reason and
# returns 1 when it cannot; the folder holds the holder's pid and start.
turn_take() {
  [ -z "${GITHUB_ACTIONS:-}" ] && [ "${SUITE_TURN:-}" != off ] || return 0
  if turn_runner_busy; then turn_runner_line; return 1; fi
  tt_d=$(turn_dir); tt_now=$(date +%s)
  if [ -d "$tt_d" ]; then
    tt_pid=$(sed -n 1p "$tt_d/holder" 2>/dev/null | tr -d '\r'); tt_at=$(sed -n 2p "$tt_d/holder" 2>/dev/null | tr -d '\r')
    if [ "$(turn_stale "$tt_at" "$tt_now" "${SUITE_TURN_BOUND:-1200}")" = yes ]; then
      rm -rf "$tt_d" 2>/dev/null
    else
      turn_busy_line "$tt_pid" "$(date -d "@$tt_at" '+%H:%M' 2>/dev/null || echo "$tt_at")"; return 1
    fi
  fi
  mkdir "$tt_d" 2>/dev/null || { turn_busy_line "?" "just now"; return 1; }
  printf '%s\n%s\n' "$$" "$tt_now" > "$tt_d/holder"
  return 0
}

# turn_give: give the turn back (only if this run holds it).
turn_give() {
  tg_d=$(turn_dir)
  [ "$(sed -n 1p "$tg_d/holder" 2>/dev/null | tr -d '\r')" = "$$" ] || return 0
  rm -rf "$tg_d" 2>/dev/null
  return 0
}
