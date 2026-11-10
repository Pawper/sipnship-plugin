#!/bin/sh
# The check runs on a pull request's head, through REST: one line per
# check run, name and outcome, then, for a red pull request, one plain line
# per failed run naming what broke (the rule and the file for a size
# failure), then the one-word rollup the merge queue reads (none, red,
# pending or green). gh pr checks goes through GraphQL, whose secondary
# limit trips first; this spends two REST calls, and one more per failed run.
#
# Usage: sh scripts/pr-checks.sh PR_NUMBER
# Exit 0 when green, 1 when red, 2 when pending or none.
set -e
here=$(dirname "$0")
. "$here/ci/batch-lib.sh"
. "$here/pr-lib.sh"
pr=$1
[ -n "$pr" ] || { echo "Usage: sh scripts/pr-checks.sh PR_NUMBER" >&2; exit 2; }
sha=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq .head.sha)
runs=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)\t\(.id)"')
if [ -z "$runs" ]; then echo "No check runs on #$pr yet ($sha)."; echo "none"; exit 2; fi
printf '%s\n' "$runs" | awk -F'\t' '{ printf "  %-40s %s\n", $1, $2 }'
rollup=$(rest_rollup "$(printf '%s\n' "$runs" | cut -f2)")
if [ "$rollup" = red ]; then
  # Why: a failed run's own annotation names its step and its lines.
  printf '%s\n' "$runs" | awk -F'\t' '$2 == "failure" || $2 == "cancelled" { print $3 "\t" $1 }' | while IFS="$(printf '\t')" read -r id name; do
    note=$(gh api "repos/{owner}/{repo}/check-runs/$id/annotations" --jq '.[] | select((.title // "") | test(" failed at ")) | (.title | sub("^.* failed at "; "")) as $step | (.message | split("\n")) as $l | $step + "\t" + (($l | map(select(test("over the limit of"))) | first) // ($l | map(select(length > 0)) | first) // "")' 2>/dev/null | head -n 1) || note=
    [ -n "$note" ] || continue
    pr_red_say "$name" "$(printf '%s' "$note" | cut -f1)" "$(printf '%s' "$note" | cut -f2-)"
  done
fi
echo "$rollup"
case "$rollup" in green) exit 0 ;; red) exit 1 ;; *) exit 2 ;; esac
