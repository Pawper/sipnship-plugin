#!/bin/sh
# Read the approval for the latest proposal on the project's drive issue.
# Read-only: it prints the approved goals, or says there is nothing to do.
#
# The drive issue is the open issue labeled "drive". A proposal is a comment
# that starts with "Proposal". An approval is the newest comment after that
# proposal written by someone other than the proposer, whose first line is
# "all", "none", a list of numbers, or "all but" a list of numbers.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/approval.sh"
# Prints: the approved goal lines, one per line, then "approved by NAME"; or
# one line saying why there is nothing: no drive issue, no proposal, no
# reply yet, or a reply that approved nothing.
here=$(dirname "$0")
. "$here/drive-lib.sh"

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "nothing: gh is not available or not signed in"
  exit 0
fi

issue=$(gh api "repos/{owner}/{repo}/issues?labels=drive&state=open&per_page=1" --jq '.[0].number' 2>/dev/null)
[ -n "$issue" ] || { echo "nothing: no open issue labeled drive"; exit 0; }

me=$(gh api user --jq .login 2>/dev/null)
tab=$(printf '\t')
comments=$(gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100" --jq '.[] | [.created_at, .user.login, (.body | gsub("\t"; " ") | gsub("\r"; ""))] | @tsv' 2>/dev/null)
[ -n "$comments" ] || { echo "nothing: no proposal on issue $issue yet"; exit 0; }

proposal=""; proposal_at=""; reply=""; reply_by=""
printf '%s\n' "$comments" | while IFS="$tab" read -r at author body; do :; done
# Walk the comments in order; keep the last proposal and the last reply after it.
state=$(printf '%s\n' "$comments" | awk -F'\t' -v me="$me" '
  {
    body = $3
    gsub(/\\n/, "\n", body)
    if (body ~ /^Proposal/) { proposal = body; at = $1; reply = ""; by = ""; next }
    if (proposal != "" && $2 != me) { first = body; sub(/\n.*/, "", first); reply = first; by = $2 }
  }
  END {
    if (proposal == "") { print "noproposal"; exit }
    if (reply == "") { print "noreply"; exit }
    print "reply\t" by "\t" reply
    print proposal
  }')

case "$state" in
  noproposal) echo "nothing: no proposal on issue $issue yet"; exit 0 ;;
  noreply) echo "nothing: the latest proposal on issue $issue has no reply yet"; exit 0 ;;
esac
head1=$(printf '%s\n' "$state" | head -n 1)
reply_by=$(printf '%s' "$head1" | cut -f2)
reply=$(printf '%s' "$head1" | cut -f3)
proposal=$(printf '%s\n' "$state" | tail -n +2)

approved=$(approved_goals "$proposal" "$reply")
if [ -z "$approved" ]; then
  echo "nothing: $reply_by replied \"$reply\" and approved no goal"
  exit 0
fi
printf '%s\n' "$approved"
echo "approved by $reply_by"
