#!/bin/sh
# For the nightly audit: every open issue waiting on the owner whose ask gives
# choices and does not recommend exactly one, one line each, "#N: what to fix."
# The same rule the state-label hook holds inside a session, for an agent
# without hooks or a state set from GitHub's own page. The ask is the newest
# comment that carries one, posted since the issue was set to waiting on the
# owner or up to ten minutes before, as the dashboard reads it. REST only, a
# few calls per waiting issue; prints nothing when all is well or GitHub
# cannot be asked. Needs GH_REPO.
here=$(dirname "$0")
. "$here/ask-lib.sh"
repo=${GH_REPO:-}
[ -n "$repo" ] || exit 0
waiting='ascii_downcase | test("^state: ?waiting-on-owner$")'
nums=$(gh api "repos/$repo/issues?state=open&per_page=100" --paginate \
  --jq ".[] | select(.pull_request | not) | select([.labels[].name | $waiting] | any) | .number" 2>/dev/null) || exit 0
for n in $nums; do
  set_at=$(gh api "repos/$repo/issues/$n/events?per_page=100" \
    --jq "[.[] | select(.event == \"labeled\" and (.label.name | $waiting))] | last | .created_at // empty" 2>/dev/null) || set_at=""
  keep='true'
  [ -z "$set_at" ] || keep="(.created_at | fromdateiso8601) >= ((\"$set_at\" | fromdateiso8601) - 600)"
  out=$(gh api "repos/$repo/issues/$n/comments?per_page=100" \
    --jq "[.[] | select($keep)] | reverse | .[] | .body, \"$ASK_NEXT\"" 2>/dev/null) || continue
  fix=$(ask_fix "$(printf '%s\n' "$out" | ask_verdict)")
  [ -z "$fix" ] || printf '#%s: %s.\n' "$n" "$fix"
done
exit 0
