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
