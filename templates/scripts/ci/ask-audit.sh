#!/bin/sh
# For the nightly audit: every open issue waiting on the owner with no ask, or
# an ask the builder cannot answer as written (no choices, not exactly one
# recommended, a choice cut off, our working words), one line each, "#N: what to fix."
# The same rule the state-label hook holds inside a session, for an agent
# without hooks or a state set from GitHub's own page. The ask is the newest
# comment that carries one, posted since the issue was set to waiting on the
# owner or up to ten minutes before, as the dashboard reads it. REST only, a
# few calls per waiting issue; prints nothing when all is well or GitHub
# cannot be asked. Needs GH_REPO, unless issue numbers are given.
#   sh ask-audit.sh                    every waiting issue, one fix line each
#   sh ask-audit.sh --verdicts N...    these issues only, "N<TAB>WORD" each
#                                      (ask_check's word), for the drive's plan
here=$(dirname "$0")
. "$here/ask-lib.sh"
words=no; [ "${1:-}" = --verdicts ] && { words=yes; shift; }
repo=${GH_REPO:-}
[ -n "$repo" ] || [ $# -eq 0 ] || repo='{owner}/{repo}'
[ -n "$repo" ] || exit 0
waiting='ascii_downcase | test("^state: ?waiting-on-owner$")'
if [ $# -gt 0 ]; then nums=$*
else
  nums=$(gh api "repos/$repo/issues?state=open&per_page=100" --paginate \
    --jq ".[] | select(.pull_request | not) | select([.labels[].name | $waiting] | any) | .number" 2>/dev/null) || exit 0
fi
for n in $nums; do
  set_at=$(gh api "repos/$repo/issues/$n/events?per_page=100" \
    --jq "[.[] | select(.event == \"labeled\" and (.label.name | $waiting))] | last | .created_at // empty" 2>/dev/null) || set_at=""
  keep='true'
  [ -z "$set_at" ] || keep="(.created_at | fromdateiso8601) >= ((\"$set_at\" | fromdateiso8601) - 600)"
  out=$(gh api "repos/$repo/issues/$n/comments?per_page=100" \
    --jq "[.[] | select($keep)] | reverse | .[] | .body, \"$ASK_NEXT\"" 2>/dev/null) || continue
  word=$(printf '%s\n' "$out" | ask_check)
  if [ "$words" = yes ]; then printf '%s\t%s\n' "$n" "$word"; continue; fi
  fix=$(ask_fix "$word")
  [ -z "$fix" ] || printf '#%s: %s.\n' "$n" "$fix"
done
exit 0
