#!/bin/sh
# A set-aside that already happened is not proposed again (#2029). Pure helpers, text in and text out;
# tests/run.sh covers them. Sourced by plan.sh, which reads the times and prints the round through them.

# settled_set_asides ROUND SETTLED
# ROUND is propose_round's goal lines; SETTLED the pull request numbers, one per line, whose set-aside is
# already done: every issue the pull request closes is state:blocked and its newest comment is newer than
# the pull request's last red run. A "set-aside N" goal for one of them becomes the unnumbered line
# "note: pull request N is already set aside; ..." so the same action is not approved and run every tick.
settled_set_asides() {
  printf '%s\n' "$1" | awk -F'\t' -v settled="$2" '
    BEGIN { n = split(settled, a, "\n"); for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); if (a[i] != "") ok[a[i]] = 1 } }
    {
      if ($1 ~ /^set-aside [0-9]+$/) {
        num = substr($1, 11)
        if (num in ok) { print "note: pull request " num " is already set aside; its issue is blocked and names the cause, written after its last red run"; next }
      }
      print
    }'
}

# set_aside_settled BLOCKED COMMENT_AT RED_AT
# "yes" when the pull request's issues are all blocked (BLOCKED is yes) and the newest comment on them
# (COMMENT_AT, epoch seconds) is later than the newest red run (RED_AT); else "no". A time not known is no.
set_aside_settled() {
  case "$1:$2:$3" in yes:[0-9]*:[0-9]*) [ "$2" -gt "$3" ] && { echo yes; return 0; } ;; esac
  echo no
}

# drop_settled_set_asides ROUND PR_LIST SNAPSHOT
# Prints ROUND with each already-done "set-aside N" goal turned into a note. PR_LIST is the plan's pull
# request rows (separated by $us; field 1 the number, 2 the branch, 5 the closed issues) and SNAPSHOT the
# board's tab rows. Reads each such pull request's issue comments and last red run over REST.
drop_settled_set_asides() {
  dss_round=$1; dss_list=$2; dss_snap=$3; dss_settled=""
  for sa_pr in $(printf '%s\n' "$dss_round" | sed -n 's/^set-aside \([0-9][0-9]*\).*/\1/p'); do
    sa_row=$(printf '%s\n' "$dss_list" | awk -F"$us" -v n="$sa_pr" '$1 == n { print $2 "\t" $5 }')
    sa_ref=$(printf '%s' "$sa_row" | cut -f1); sa_issues=$(printf '%s' "$sa_row" | cut -f2 | tr ',' ' ')
    [ -n "$sa_issues" ] || continue
    sa_blocked=yes; sa_comment=0
    for sa_i in $sa_issues; do
      [ "$(printf '%s\n' "$dss_snap" | awk -F'\t' -v n="$sa_i" '$1 == "issue" && $2 == n { print $4 }')" = blocked ] || { sa_blocked=no; break; }
      sa_c=$(gh api "repos/{owner}/{repo}/issues/$sa_i/comments?per_page=100" --jq '[.[].created_at | fromdateiso8601] | max // 0' 2>/dev/null | tr -d '\r')
      case "$sa_c" in [0-9]*) sa_comment=$sa_c ;; *) sa_blocked=no; break ;; esac
    done
    [ "$sa_blocked" = yes ] || continue
    sa_red=$(gh api "repos/{owner}/{repo}/actions/runs?branch=$sa_ref&event=pull_request&status=failure&per_page=100" --jq '[.workflow_runs[].created_at | fromdateiso8601] | max // 0' 2>/dev/null | tr -d '\r')
    [ "$(set_aside_settled "$sa_blocked" "$sa_comment" "$sa_red")" = yes ] && dss_settled="${dss_settled}${sa_pr}
"
  done
  if [ -n "$dss_settled" ]; then settled_set_asides "$dss_round" "$dss_settled"; else printf '%s\n' "$dss_round"; fi
}
