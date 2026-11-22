#!/bin/sh
# An In progress issue with no agent, no open pull request and no commit on its branch is free to pick up again, never read
# as running (#2267). An agent that found nothing left to build once left an issue In progress for eight hours; the plan
# took it for a running unit and held what shared its files. Pure: text in, text out. Sourced by plan.sh.

# idle_in_progress FACTS PULLS BRANCHES NOW UNITS [GRACE]
# FACTS are board-now's lines; PULLS the plan's pull lines (NUMBER<TAB>HELD<TAB>CLOSES); BRANCHES "EPOCH<TAB>REF" for each
# branch's newest commit; NOW epoch seconds; UNITS the started round's units ("PR<TAB>ISSUES"), whose issues an agent was
# sent to. GRACE (default 900 seconds) is how long a freshly started issue has before its first branch or pull request:
# one touched more recently than that is still starting. Prints the numbers, one a line.
idle_in_progress() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v pulls="$2" -v branches="$3" -v now="$4" -v units="$5" -v grace="${6:-900}" '
    function epoch(iso,   cmd, t) { cmd = "date -u -d \"" iso "\" +%s 2>/dev/null"; cmd | getline t; close(cmd); return t + 0 }
    BEGIN {
      n = split(pulls, pl, "\n"); for (i = 1; i <= n; i++) { split(pl[i], f, "\t"); k = split(f[3], c, ","); for (j = 1; j <= k; j++) if (c[j] != "") pr[c[j]] = 1 }
      n = split(units, ul, "\n"); for (i = 1; i <= n; i++) { split(ul[i], f, "\t"); k = split(f[2], c, " "); for (j = 1; j <= k; j++) if (c[j] != "") un[c[j]] = 1 }
      nb = split(branches, bl, "\n")
    }
    $1 == "issue" && tolower($4) ~ /(^|,)state: ?in[- ]progress(,|$)/ {
      num = $2
      if (num in pr) next
      if (num in un) next
      for (i = 1; i <= nb; i++) { split(bl[i], f, "\t"); if (f[2] ~ ("(^|[^0-9])" num "([^0-9]|$)") && f[2] !~ /^(origin\/)?fixside\//) next_issue = 1 }
      if (next_issue) { next_issue = 0; next }
      if ($5 ~ /^[0-9][0-9][0-9][0-9]-/ && now - epoch($5) < grace) next
      print num
    }'
}
