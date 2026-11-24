#!/bin/sh
# A red change that ready work waits on is the first thing a look does something about (#2445, specs/023-drive-on-work,
# "A stall is named"). Text in, text out; sourced by plan.sh and fix-owed.sh.
#
# The case: a change opened at 2:28 PM went red on two checks while others still ran, its agent had already finished and
# freed its claim, and the round of 2:35 PM held eight ready issues behind it and started nothing: no fix agent, and
# nothing else. Three rules follow, each a function here.
#   1. The more issues wait on a red change nobody is on, the sooner a fix agent goes (red_waiters, and wake-lib's
#      wake_fix_owed, which takes the count as its sixth field).
#   2. A fix agent for it leads the round, ahead of any new work, even while its other checks still run: the round says
#      so on that goal's own line (red_wait_lead).
#   3. When everything ready waits on one such change, the round says that in one line, with whose turn it is
#      (red_wait_stall).

# red_waiters HOLDS CLOSES
# HOLDS are a round's hold lines, either the plan's own ("hold N<TAB>TITLE<TAB>WHY (after: 12 14)") or the published round
# file's ("hold: N | why: ... | after: 12 14 | areas: none"); CLOSES the issue numbers a change closes (comma or space
# separated). Prints how many held issues wait on any of them.
red_waiters() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v c=" $(printf '%s' "$2" | tr ',' ' ') " '
    /^hold/ {
      if (!match($0, /after: [0-9 ,#]+/)) next
      list = substr($0, RSTART + 7, RLENGTH - 7); gsub(/[,#]/, " ", list)
      k = split(list, a, " "); for (i = 1; i <= k; i++) if (index(c, " " a[i] " ")) { n++; break }
    }
    END { print n + 0 }'
}

# any_failed LINES
# LINES are a head commit's check runs, "STATUS<TAB>CONCLUSION" each. "yes" when at least one has ended failed, whether or
# not others still run: a red change that other work waits on is not left until its slowest check ends.
any_failed() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 == "completed" && ($2 == "failure" || $2 == "cancelled" || $2 == "timed_out") { bad = 1 } END { print (bad ? "yes" : "no") }'
}

# red_wait_goal SNAPSHOT PULLS ROUND
# The red changes nobody is on that ready work waits on, as "NUMBER<TAB>TITLE<TAB>WAITERS" lines, the one most issues wait on
# first. SNAPSHOT is the plan's rows (pr rows: number, title, checks, merge state, ..., held at 8, busy at 9, reds that came
# from main at 11); PULLS "NUMBER<TAB>HELD<TAB>CLOSES"; ROUND the goal lines. A change held for the builder, one an agent is
# on (a recent push), and one whose reds came from main wait for something else and are left out.
red_wait_goal() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 == "pr" && $4 == "red" && $8 != "yes" && $9 != "yes" && $11 != "waiting" && $11 != "fixed" { print $2 "\t" $3 }' \
    | while IFS="$(printf '\t')" read -r rw_n rw_title; do
      [ -n "$rw_n" ] || continue
      rw_closes=$(printf '%s\n' "$2" | tr -d '\r' | awk -F'\t' -v n="$rw_n" '$1 == n { print $3; exit }')
      [ -n "$rw_closes" ] || continue
      rw_w=$(red_waiters "$3" "$rw_closes")
      [ "$rw_w" -gt 0 ] 2>/dev/null && printf '%s\t%s\t%s\n' "$rw_n" "$rw_title" "$rw_w"
    done | sort -t"$(printf '\t')" -k3,3nr -k1,1n
}

# red_wait_lead ROUND SNAPSHOT PULLS
# ROUND with a fix-pr goal for each such change at its head, ahead of any new work, saying how many issues wait on it. A
# goal the round already had for that change (fix-pr, or busy because its other checks still run) is replaced by it.
red_wait_lead() {
  rw_goals=$(red_wait_goal "$2" "$3" "$1")
  [ -n "$rw_goals" ] || { printf '%s\n' "$1"; return 0; }
  { printf '%s\n' "$rw_goals" | sed 's/^/G\t/'; printf '%s\n' "$1" | sed 's/^/R\t/'; } | awk -F'\t' '
    $1 == "G" { n++; num[n] = $2; line[n] = "fix-pr " $2 "\t" $3 "\tFirst: " $4 " ready issue" ($4 == 1 ? "" : "s") " wait" ($4 == 1 ? "s" : "") " on it, and it is red with nobody on it; a fix agent goes ahead of any new work"; mine[$2] = 1; next }
    $1 == "R" {
      head = $2; sub(/\t.*/, "", head)
      if (head ~ /^(fix-pr|busy) [0-9]+$/ && substr(head, index(head, " ") + 1) in mine) next
      rest[++r] = substr($0, 3); next }
    END { for (i = 1; i <= n; i++) print line[i]; for (i = 1; i <= r; i++) print rest[i] }'
}

# red_wait_stall ROUND SNAPSHOT PULLS STALL
# STALL is the stall line the plan already made (or nothing). When no unit is dispatched and every held issue waits on one red
# change nobody is on, the line says so plainly, with whose turn it is: the drive's, so nothing is owed by the builder.
# Otherwise STALL is printed as it was.
red_wait_stall() {
  rs_top=$(red_wait_goal "$2" "$3" "$1" | head -n 1)
  rs_held=$(printf '%s\n' "$1" | tr -d '\r' | grep -c '^hold [0-9]')
  if [ -n "$rs_top" ] && ! printf '%s\n' "$1" | grep -q '^dispatch ' && [ "$rs_held" -gt 0 ] && [ "$(printf '%s' "$rs_top" | cut -f3)" -ge "$rs_held" ]; then
    printf 'stall: every ready issue (%s) waits on "%s", which is red with nobody on it; your drive sends a fix agent to it first, and nothing is owed by you\n' "$rs_held" "$(printf '%s' "$rs_top" | cut -f2)"
  else
    printf '%s\n' "$4" | sed '/^$/d'
  fi
}
