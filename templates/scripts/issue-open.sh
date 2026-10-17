#!/bin/sh
# File an issue through REST, with the body read from a file and its State
# label in the same call, and print its address. gh issue create goes
# through GraphQL, whose hourly budget seven agents can spend in an
# afternoon; REST has its own. A body in a file also keeps the Bash call
# short enough for the task window.
#
# Usage: sh scripts/issue-open.sh "TITLE" BODY_FILE state:ready [LABEL...]
set -e
title=$1; body_file=$2; shift 2 2>/dev/null || true
[ -n "$title" ] && [ -n "$body_file" ] && [ $# -gt 0 ] || { echo 'Usage: sh scripts/issue-open.sh "TITLE" BODY_FILE state:ready [LABEL...]' >&2; exit 2; }
[ -f "$body_file" ] || { echo "No such body file: $body_file (write it under .scratch/)" >&2; exit 2; }
case " $* " in *" state:"*) ;; *) echo "Every issue carries its State at filing: add state:ready (or state:in-progress, state:waiting-on-owner, state:waiting-on-service, state:parked, state:dated, state:after-launch)." >&2; exit 2 ;; esac
set -- "$@"
labels=""
for l in "$@"; do labels="$labels -f labels[]=$l"; done
# shellcheck disable=SC2086
out=$(gh api -X POST "repos/{owner}/{repo}/issues" -f title="$title" -F body=@"$body_file" $labels --jq '"\(.number)\t\(.html_url)"' 2>&1) || {
  case "$out" in
    *"rate limit"*|*"secondary"*) echo "GitHub refused the call for its rate limit; wait 90 seconds and run it again, never at once." >&2; exit 1 ;;
    *) printf '%s\n' "$out" >&2; exit 1 ;;
  esac
}
echo "Filed issue #${out%%	*}: ${out#*	}"
