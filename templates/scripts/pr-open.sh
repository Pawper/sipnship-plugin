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
title=$1; body_file=$2; base=${3:-main}; head=${4:-$(git rev-parse --abbrev-ref HEAD)}
[ -n "$title" ] && [ -n "$body_file" ] || { echo 'Usage: sh scripts/pr-open.sh "TITLE" BODY_FILE [BASE] [HEAD]' >&2; exit 2; }
[ -f "$body_file" ] || { echo "No such body file: $body_file (write it under .scratch/)" >&2; exit 2; }
[ "$head" != HEAD ] || { echo "Detached HEAD; name the head branch as the fourth argument." >&2; exit 2; }
git ls-remote --exit-code --heads origin "$head" >/dev/null 2>&1 || { echo "The branch $head is not on origin yet; push it first." >&2; exit 2; }
out=$(gh api -X POST "repos/{owner}/{repo}/pulls" -f base="$base" -f head="$head" -f title="$title" -F body=@"$body_file" --jq '"\(.number)\t\(.html_url)"' 2>&1) || {
  case "$out" in
    *"A pull request already exists"*) echo "A pull request for $head already exists:"; gh api "repos/{owner}/{repo}/pulls?head={owner}:$head&state=open" --jq '.[] | "#\(.number) \(.html_url)"'; exit 0 ;;
    *"rate limit"*|*"secondary"*) echo "GitHub refused the call for its rate limit; wait 90 seconds and run it again, never at once." >&2; exit 1 ;;
    *) printf '%s\n' "$out" >&2; exit 1 ;;
  esac
}
echo "Opened pull request #${out%%	*}: ${out#*	}"
