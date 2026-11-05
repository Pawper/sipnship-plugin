#!/bin/sh
# Pure helpers for two lines of the session brief, sourced by the brief's
# slots and by tests/run.sh. Nothing here runs git or gh.

# iso_epoch STAMP
# STAMP is a UTC time as gh prints it, 2026-11-04T23:10:00Z. Print epoch
# seconds, or nothing when it is not one.
iso_epoch() {
  printf '%s\n' "$1" | awk '
    match($0, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
      y = substr($0, 1, 4) + 0; m = substr($0, 6, 2) + 0; d = substr($0, 9, 2) + 0
      if (m <= 2) y--
      era = int(y / 400); yoe = y - era * 400
      mp = (m + 9) % 12
      doy = int((153 * mp + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      days = era * 146097 + doe - 719468
      printf "%d\n", days * 86400 + substr($0, 12, 2) * 3600 + substr($0, 15, 2) * 60 + substr($0, 18, 2)
    }'
}

# unattended_red_lines FACTS NOW MINUTES
# FACTS is board-now.sh's output, NOW epoch seconds. A pull request whose
# checks are red and which nothing has touched for MINUTES (a commit, a
# comment, a label) has nobody on it: its agent finished and the queue does
# not re-run a failure that came from its own change. One line naming them,
# or nothing.
unattended_red_lines() {
  printf '%s\n' "$1" | tr -d '\r' | while IFS='	' read -r k n t r m b f u; do
    [ "$k" = pr ] && { [ "$r" = FAILURE ] || [ "$r" = ERROR ]; } || continue
    e=$(iso_epoch "$u"); [ -n "$e" ] || continue
    age=$(( ($2 - e) / 60 ))
    if [ "$age" -ge "$3" ]; then printf '%s\t%s\t%s\n' "$n" "$t" "$age"; fi
  done | awk -F'\t' '
    { c++; if (c <= 4) { list = list (c > 1 ? "; " : "") "#" $1 " " $2 " (red, untouched " $3 " min)" } }
    END {
      if (c == 0) exit
      if (c > 4) list = list "; and " (c - 4) " more"
      printf "Red with nobody on it: %s. The agent that built it has finished, and the queue does not re-run a failure from the change itself. Send an agent to fix it, or say it is set aside.\n", list
    }'
}

# handoff_comment_line ROW NOW LOCAL
# ROW is the newest handoff on the drive issue as handoff.sh last prints it,
# "epoch<TAB>url". LOCAL is that moment in the owner's local time. One line
# for the brief: when it was written, how long ago, and where.
handoff_comment_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v local="$3" '
    $1 ~ /^[0-9]+$/ && $2 != "" {
      s = now - $1; if (s < 0) s = 0
      if (s < 3600) ago = int(s / 60) " min ago"
      else if (s < 172800) ago = int(s / 3600) " h ago"
      else ago = int(s / 86400) " days ago"
      printf "Last handoff, on the drive issue: written %s (%s). Read it first: %s\n", local, ago, $2
      exit
    }'
}
