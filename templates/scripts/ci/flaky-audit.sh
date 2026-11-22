#!/bin/sh
# The tests that flaked more than once in the last week, one line each, from
# the flake notes on the red-main issues closed in that time. Nothing when none.
# Needs GH_TOKEN and GH_REPO; REST only.
here=$(dirname "$0")
. "$here/flake-lib.sh"
repo=${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
since=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)
text=
for n in $(gh api "repos/$repo/issues?labels=ci-red&state=closed&since=$since&per_page=50" --jq '.[].number' 2>/dev/null | tr -d '\r'); do
  text="$text
$(gh api "repos/$repo/issues/$n/comments?per_page=100" --jq '.[].body' 2>/dev/null)"
done
flaky_report "$text"
