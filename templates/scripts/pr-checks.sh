#!/bin/sh
# The check runs on a pull request's head, through REST: one line per
# check run, name and outcome, then the one-word rollup the merge queue
# reads (none, red, pending or green). gh pr checks goes through GraphQL,
# whose secondary limit trips first; this spends two REST calls.
#
# Usage: sh scripts/pr-checks.sh PR_NUMBER
# Exit 0 when green, 1 when red, 2 when pending or none.
set -e
here=$(dirname "$0")
. "$here/ci/batch-lib.sh"
pr=$1
[ -n "$pr" ] || { echo "Usage: sh scripts/pr-checks.sh PR_NUMBER" >&2; exit 2; }
sha=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq .head.sha)
runs=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)"')
if [ -z "$runs" ]; then echo "No check runs on #$pr yet ($sha)."; echo "none"; exit 2; fi
printf '%s\n' "$runs" | awk -F'\t' '{ printf "  %-40s %s\n", $1, $2 }'
rollup=$(rest_rollup "$(printf '%s\n' "$runs" | cut -f2)")
echo "$rollup"
case "$rollup" in green) exit 0 ;; red) exit 1 ;; *) exit 2 ;; esac
