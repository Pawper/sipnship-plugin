#!/bin/sh
# Main went green again: when the red-main issue still open holds exactly one
# red run, the very next run on main cleared it with no fix. Record that on the
# issue as a flake, naming the test, before CI closes it; the audit counts the
# "Flaky test:" lines (flaky-audit.sh).
#   sh scripts/ci/report-flake.sh GREEN_RUN_ID
# Needs GH_TOKEN and GH_REPO; REST only.
here=$(dirname "$0")
. "$here/flake-lib.sh"
repo=${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
server=${GITHUB_SERVER_URL:-https://github.com}
url="$server/$repo/actions/runs/$1"
for n in $(gh api "repos/$repo/issues?labels=ci-red&state=open&per_page=20" --jq '.[].number' 2>/dev/null | tr -d '\r'); do
  text=$(gh api "repos/$repo/issues/$n" --jq '.body' 2>/dev/null; gh api "repos/$repo/issues/$n/comments?per_page=100" --jq '.[].body' 2>/dev/null)
  [ "$(flake_decision "$text")" = yes ] || continue
  gh api "repos/$repo/issues/$n/comments" -f body="$(flake_note "$text" "$url")" >/dev/null && echo "Recorded the flake on #$n."
done
