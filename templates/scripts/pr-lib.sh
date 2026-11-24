#!/bin/sh
# Pure helper for pr-open.sh. Text in, text out.
#
# GitHub closes an issue when a pull request body holds a closing keyword
# (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved,
# with or without a colon) followed by #N or owner/repo#N, wherever it
# stands in the sentence. "Filed rather than fixed: #105" closes #105. The
# one deliberate form is a line that starts with "Closes #N".

# pr_stray_closers BODY
# The lines of BODY holding a closing keyword that would close an issue
# other than by a line starting "Closes #N", one per line. Empty when none.
# On a deliberate line only its leading "Closes #N" is allowed; a second
# keyword on the same line is a stray.
pr_stray_closers() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    BEGIN {
      kw = "(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)"
      re = "(^|[^a-z0-9_])" kw ":?[ \t]*([a-z0-9_.-]+/[a-z0-9_.-]+)?#[0-9]+"
    }
    {
      low = tolower($0); n = 0; rest = low; off = 0
      while (match(rest, re)) {
        n++
        if (!(n == 1 && $0 ~ /^Closes #[0-9]+/ && off + RSTART == 1)) { print $0; break }
        off += RSTART + RLENGTH - 1
        rest = substr(low, off + 1)
      }
    }'
}

# pr_red_say JOB STEP LINE
# One plain line for a failed check run: the job, then what broke. LINE is
# the failing step's error line as the run's annotation carries it. A size
# failure from the hotspots check is said as the file and its count; any
# other says its step and the line.
pr_red_say() {
  prs_size=$(printf '%s\n' "$3" | sed 's/ is new and has / has /' | sed -n 's/^\(.*[^ ]\) has \([0-9][0-9]*\) lines, over the limit of \([0-9][0-9]*\).*$/\1|\2|\3/p' | head -n 1)
  if [ -n "$prs_size" ]; then
    printf '%s: a file grew past its size limit: %s, %s of %s lines\n' "$1" "${prs_size%%|*}" "$(printf '%s' "$prs_size" | cut -d'|' -f2)" "${prs_size##*|}"
  elif [ -n "$3" ]; then
    printf '%s: %s failed: %s\n' "$1" "${2:-a step}" "$3"
  else
    printf '%s: %s failed\n' "$1" "${2:-a step}"
  fi
}

# pr_body_held BODY
# "yes" when BODY carries a "Queue: hold" line (the queue and the drive read it as they read the queue:hold
# label), else "no".
pr_body_held() {
  if printf '%s\n' "$1" | tr -d '\r' | grep -qiE '^[[:space:]]*Queue:[[:space:]]*hold'; then echo yes; else echo no; fi
}

# checks_wait_bound AHEAD
# How many minutes an agent waits for its change's checks to end, given AHEAD runs in line before them
# (queued, other changes'): a floor of twenty minutes and eight more for each run ahead, so a busy hour
# is waited out and an idle one is not (#2559).
checks_wait_bound() {
  cwb_n=${1:-0}; case "$cwb_n" in ''|*[!0-9]*) cwb_n=0 ;; esac
  echo $((20 + 8 * cwb_n))
}

# checks_poll_gap BUDGET
# Seconds between two reads of a change's checks while waiting: one every few minutes, slower as the
# hour's budget falls (BUDGET is the points left; empty or unknown reads as plenty).
checks_poll_gap() {
  case "${1:-}" in ''|*[!0-9]*) echo 240; return 0 ;; esac
  if [ "$1" -ge 3000 ]; then echo 240; elif [ "$1" -ge 1500 ]; then echo 360; elif [ "$1" -ge 500 ]; then echo 600; else echo 900; fi
}

# checks_line_say AHEAD RUNNING ONLINE BUSY
# The one line every agent reads the same: the runs in line ahead of the change's checks and the machines'
# state. ONLINE and BUSY are counts of the machines that take this project's jobs, or "?" when the
# token cannot list them.
checks_line_say() {
  case "$3" in '?') cls_m="machines: not known (the token cannot list them)" ;; *) cls_m="machines: $3 online, ${4:-0} working" ;; esac
  printf 'Line: %s run(s) waiting ahead, %s running; %s\n' "${1:-0}" "${2:-0}" "$cls_m"
}

# checks_wait_decide AHEAD ONLINE WAITED_MINUTES
# Whether an agent keeps waiting. Prints "wait: waiting behind N runs (...)" while a machine that can take
# its jobs is online (or not known) and the bound for the line is not past; otherwise "leave: WHY", in
# words that go on the change as they are. Checks not yet started are waiting in line, not failing to start.
checks_wait_decide() {
  cwd_b=$(checks_wait_bound "$1")
  if [ "$2" = 0 ]; then
    printf 'leave: no machine that can take its jobs is online, so the checks cannot start until one is\n'
  elif [ "${3:-0}" -gt "$cwd_b" ] 2>/dev/null; then
    printf 'leave: the checks have waited %s minutes, past the %s minutes a line of %s run(s) is given\n' "$3" "$cwd_b" "${1:-0}"
  else
    printf 'wait: waiting behind %s runs (leave only after %s minutes, or when no machine is online)\n' "${1:-0}" "$cwd_b"
  fi
}
