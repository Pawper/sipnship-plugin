#!/bin/sh
# Read the red changes nobody is on, for the wake to ask a fix agent for before it
# plans (specs/023-drive-on-work, "A stall is named"). Read-only, no model: one line
# a pull request, "fix-agent N", or nothing. A pull request is owed one when its
# newest commit's checks ended red, it is not held for the builder, its last push is
# about five minutes old, and no "Fix agent asked" comment is newer than that push.
# Ready issues that wait on a change (the last round's own hold lines, no call) shorten its wait and let it go while its other
# checks still run (red-wait-lib.sh, #2445). REST only: one list of the open pull requests, then per pull request its checks,
# and, only for a red one, its head commit's time and its comments.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/fix-owed.sh"
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/../../hooks/scripts/board-checks-lib.sh"
. "$here/round-lib.sh"
. "$here/plan-green-lib.sh"
. "$here/wake-lib.sh"
. "$here/fix-side-lib.sh"
. "$here/red-wait-lib.sh"

command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || exit 0
rows=""
tab=$(printf '\t')
list=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [(.number | tostring), .head.sha, ([.labels[].name] | join(",")), ((.body // "") | [splits("\r?\n")] | map(select(test("^Queue: hold"; "i"))) | first // ""), ((.body // "") | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]] | join(","))] | join("\u001f")' 2>/dev/null | tr -d '\r')
round_text=$(cat .scratch/drive/round.txt 2>/dev/null)
us=$(printf '\037')  # not whitespace, so an empty hold field keeps its place and the Closes numbers are not shifted into it
while IFS="$us" read -r n sha labels hold closes; do
  [ -n "$n" ] && [ -n "$sha" ] || continue
  [ "$(held_by "$labels" "$hold")" = yes ] && continue
  waiters=0; [ -z "$closes" ] || waiters=$(red_waiters "$round_text" "$closes")
  # Settled red, or, with ready work waiting on it, one check failed while others still run.
  [ "$(head_settled_red "$sha")" = yes ] || { [ "$waiters" -gt 0 ] && [ "$(any_failed "$(head_check_lines "$sha")")" = yes ]; } || continue
  # A fix already waits on a side branch (fix-side-lib.sh): fix-side.sh frees it, and asks again only if that fails (#2260).
  if gh api "repos/{owner}/{repo}/git/matching-refs/heads/$(fix_side_branch "$n")" --jq '.[].ref' 2>/dev/null | grep -q .; then
    [ "$(fix_side_failed "$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" --jq '.[].body' 2>/dev/null)")" = yes ] || continue
  fi
  pushed=$(gh api "repos/{owner}/{repo}/commits/$sha" --jq '.commit.committer.date | fromdateiso8601' 2>/dev/null | tr -d '\r')
  asked=$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" --jq '[.[] | select(.body | startswith("Fix agent asked")) | (.created_at | fromdateiso8601)] | max // empty' 2>/dev/null | tr -d '\r')
  rows="${rows}${n}${tab}yes${tab}no${tab}${pushed}${tab}${asked}${tab}${waiters}
"
done <<EOF_FIX
$list
EOF_FIX
wake_fix_owed "$(date +%s)" "$rows"
exit 0
