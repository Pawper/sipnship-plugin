#!/bin/sh
# The check runs on a pull request's head, through REST: one line per
# check run, name and outcome, then, for a failed run, one plain line naming
# what broke (the rule and the file for a size failure), then the one-word
# rollup the merge queue reads (none, red, pending or green). A check that
# failed and then cancelled its own run is recorded cancelled, but its own
# annotation names the failed step, so it counts as the failure it is.
# gh pr checks goes through GraphQL, whose secondary limit trips first; this
# spends two REST calls, and one more per failed or cancelled run.
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
# While checks have not ended, say how many runs stand ahead and what the machines are doing, so every
# agent reads the same answer (#2559): waiting in line is not the same as not starting.
say_line() {
  l_q=$(gh api "repos/{owner}/{repo}/actions/runs?status=queued&per_page=100" --jq "[.workflow_runs[] | select(.head_sha != \"$sha\")] | length" 2>/dev/null) || l_q=0
  l_r=$(gh api "repos/{owner}/{repo}/actions/runs?status=in_progress&per_page=100" --jq "[.workflow_runs[] | select(.head_sha != \"$sha\")] | length" 2>/dev/null) || l_r=0
  l_m=$(gh api "repos/{owner}/{repo}/actions/runners" --jq '[.runners[] | select(.status == "online")] as $o | "\($o | length) \([$o[] | select(.busy)] | length)"' 2>/dev/null) || l_m="? 0"
  [ -n "$l_m" ] || l_m="? 0"
  checks_line_say "${l_q:-0}" "${l_r:-0}" "${l_m% *}" "${l_m#* }"
}
if [ -z "$runs" ]; then echo "No check runs on #$pr yet ($sha)."; say_line; echo "none"; exit 2; fi
why=""; seen=""
while IFS="$(printf '\t')" read -r name outcome id; do
  case "$outcome" in failure|cancelled) ;; *) seen="$seen$name	$outcome
"; continue ;; esac
  # Its own annotation names its step and lines.
  note=$(gh api "repos/{owner}/{repo}/check-runs/$id/annotations" --jq '.[] | select((.title // "") | test(" failed at ")) | (.title | sub("^.* failed at "; "")) as $step | (.message | split("\n")) as $l | $step + "\t" + (($l | map(select(test("over the limit of"))) | first) // ($l | map(select(length > 0)) | first) // "")' 2>/dev/null | head -n 1) || note=
  if [ -n "$note" ]; then
    outcome=failure
    why="$why$(pr_red_say "$name" "$(printf '%s' "$note" | cut -f1)" "$(printf '%s' "$note" | cut -f2-)")
"
  fi
  seen="$seen$name	$outcome
"
done <<EOF
$runs
EOF
printf '%s' "$seen" | awk -F'\t' 'NF { printf "  %-40s %s\n", $1, $2 }'
rollup=$(rest_rollup "$(printf '%s' "$seen" | cut -f2)")
[ -z "$why" ] || printf '%s' "$why"
case "$rollup" in pending) say_line ;; esac
echo "$rollup"
case "$rollup" in green) exit 0 ;; red) exit 1 ;; *) exit 2 ;; esac
