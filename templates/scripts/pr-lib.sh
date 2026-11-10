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
