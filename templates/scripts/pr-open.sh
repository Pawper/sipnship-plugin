#!/bin/sh
# Open a pull request through REST, with the body read from a file, and
# print its address. gh pr create goes through GraphQL, whose secondary
# limit on concurrent calls trips first when many agents work at once;
# REST has its own budget. A body in a file also keeps the Bash call short
# enough for the task window.
#
# Usage: sh scripts/pr-open.sh "TITLE" BODY_FILE [BASE] [HEAD]
#   BASE defaults to main; HEAD to the current branch.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pr-lib.sh"
title=$1; body_file=$2; base=${3:-main}; head=${4:-$(git rev-parse --abbrev-ref HEAD)}
[ -n "$title" ] && [ -n "$body_file" ] || { echo 'Usage: sh scripts/pr-open.sh "TITLE" BODY_FILE [BASE] [HEAD]' >&2; exit 2; }
[ -f "$body_file" ] || { echo "No such body file: $body_file (write it under .scratch/)" >&2; exit 2; }
[ "$head" != HEAD ] || { echo "Detached HEAD; name the head branch as the fourth argument." >&2; exit 2; }
stray=$(pr_stray_closers "$(cat "$body_file")")
if [ -n "$stray" ]; then
  echo "The body would close an issue by accident. GitHub closes #N after close, fix or resolve in any form, anywhere in the text:" >&2
  printf '  %s\n' "$stray" >&2
  echo 'Reword each as "files #N" or "see #N"; only a line starting "Closes #N" should close an issue. Nothing was opened.' >&2
  exit 2
fi
git ls-remote --exit-code --heads origin "$head" >/dev/null 2>&1 || { echo "The branch $head is not on origin yet; push it first." >&2; exit 2; }
out=$(gh api -X POST "repos/{owner}/{repo}/pulls" -f base="$base" -f head="$head" -f title="$title" -F body=@"$body_file" --jq '"\(.number)\t\(.html_url)"' 2>&1) || {
  case "$out" in
    *"A pull request already exists"*) echo "A pull request for $head already exists:"; gh api "repos/{owner}/{repo}/pulls?head={owner}:$head&state=open" --jq '.[] | "#\(.number) \(.html_url)"'; exit 0 ;;
    *"rate limit"*|*"secondary"*) echo "GitHub refused the call for its rate limit; wait 90 seconds and run it again, never at once." >&2; exit 1 ;;
    *) printf '%s\n' "$out" >&2; exit 1 ;;
  esac
}
pr_num=${out%%	*}
# A body that says "Queue: hold" is held the moment it opens, label or no: the label is added here, so the line
# and the label never disagree and the queue cannot land it unread.
if [ "$(pr_body_held "$(cat "$body_file")")" = yes ]; then
  if gh api -X POST "repos/{owner}/{repo}/issues/$pr_num/labels" -f 'labels[]=queue:hold' >/dev/null 2>&1; then
    echo "Its body says Queue: hold, so queue:hold is on it and the queue will not land it unread."
  else
    echo "Its body says Queue: hold but queue:hold could not be set; set it by hand." >&2
  fi
fi
echo "Opened pull request #$pr_num: ${out#*	}"
