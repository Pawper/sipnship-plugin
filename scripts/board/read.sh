#!/bin/sh
# Read the board in full, but only what changed. Two calls at most:
#   1. the cheap one (board-now.sh): every open item with its last-updated
#      time;
#   2. one aliased query with the body, comments and reviews of the items
#      whose saved summary is missing or older than that time.
# With nothing changed there is no second call and no reader to dispatch.
#
# Full text goes to .scratch/board/items/, one file per item. This script
# prints only counts and the batches for readers, never the text, so the
# orchestrator's context stays small. Summaries are saved by digest.sh.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/board/read.sh" [--batch 8] [--all]
# --all re-reads every open item, ignoring the saved digest.
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/board-lib.sh"

size=8; all=no
while [ $# -gt 0 ]; do
  case "$1" in --batch) shift; size=$1 ;; --all) all=yes ;; esac
  shift
done

dir=.scratch/board
mkdir -p "$dir/items"
facts=$(sh "$here/../../hooks/scripts/board-now.sh" 2>"$dir/facts.err") || facts=""
if [ -z "$facts" ]; then
  if [ "$(gh_refusal "$(cat "$dir/facts.err" 2>/dev/null)")" = yes ]; then echo "GitHub refused the board read for its rate limit (GraphQL's secondary limit); try again in a few minutes."; exit 1; fi
  echo "gh is not available or not signed in; the board cannot be read."; exit 0
fi
printf '%s\n' "$facts" > "$dir/facts.tsv"

digest=""
[ "$all" = no ] && [ -f "$dir/digest.tsv" ] && digest=$(cat "$dir/digest.tsv")
changed=$(changed_items "$facts" "$digest")
total=$(open_items "$facts" | sed '/^$/d' | wc -l | tr -d ' ')
count=$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$count" -eq 0 ]; then
  echo "$total open items; every summary is current. Nothing to read. Show the digest with: sh \"$here/digest.sh\" show"
  exit 0
fi

item='__typename
  ... on Issue { number title state updatedAt body labels(first:10){nodes{name}}
    comments(last:15){totalCount nodes{author{login} createdAt body}}
    closedByPullRequestsReferences(first:5){nodes{number state}} }
  ... on PullRequest { number title state updatedAt body reviewDecision mergeable labels(first:10){nodes{name}}
    comments(last:15){totalCount nodes{author{login} createdAt body}}
    reviews(last:5){nodes{author{login} state body}}
    closingIssuesReferences(first:5){nodes{number}} }'

paths=""
# Twenty-five items per query keeps each response well inside the limits.
printf '%s\n' "$changed" | cut -f1 | awk 'NF { printf "%s%s", $1, (NR % 25 == 0 ? "\n" : " ") } END { print "" }' | while IFS= read -r chunk; do
  [ -n "$chunk" ] || continue
  body=""
  for n in $chunk; do body="$body i$n: issueOrPullRequest(number: $n) { $item }"; done
  gh api graphql -F owner='{owner}' -F name='{repo}' \
    -f query="query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){ $body }}" \
    --jq '.data.repository | to_entries[] | .value | select(. != null) |
      "@@@\t\(if .__typename == "PullRequest" then "pr" else "issue" end)\t\(.number)\t\(.updatedAt)\n"
      + "# \(.title)\n\n"
      + "Kind: \(.__typename). State: \(.state). Labels: \([.labels.nodes[].name] | join(", ")). Last updated: \(.updatedAt).\n"
      + (if .__typename == "PullRequest" then "Review decision: \(.reviewDecision // "none"). Mergeable: \(.mergeable). Closes: \([.closingIssuesReferences.nodes[].number | tostring] | join(", ")).\n"
         else "Pull requests that close it: \([.closedByPullRequestsReferences.nodes[] | "#\(.number) \(.state)"] | join(", ")).\n" end)
      + "\n## Body\n\n\(.body)\n\n## Comments (\(.comments.totalCount) in all, the last \(.comments.nodes | length) shown)\n\n"
      + ([.comments.nodes[] | "### \(.author.login // "someone") at \(.createdAt)\n\n\(.body)\n"] | join("\n"))
      + (if .__typename == "PullRequest" then "\n## Reviews\n\n" + ([.reviews.nodes[] | "### \(.author.login // "someone"): \(.state)\n\n\(.body)\n"] | join("\n")) else "" end)' 2>/dev/null
done | awk -v dir="$dir/items" -F'\t' '
  /^@@@\t/ { if (out != "") close(out); out = dir "/" $2 "-" $3 ".md"; print out > (dir "/../paths.new"); printf "" > out; next }
  out != "" { print >> out }'

paths=$(cat "$dir/paths.new" 2>/dev/null)
mv "$dir/paths.new" "$dir/paths.last" 2>/dev/null || true
written=$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')

echo "$total open items; $count changed since their last summary; $written written to $dir/items/."
echo "Give each line below to one reader; each returns one line per file as: NUMBER | BALL | NEXT | BLOCKER | SUMMARY"
batch_paths "$paths" "$size" | awk '{ printf "batch %d: %s\n", NR, $0 }'
echo "Save what they return with: sh \"$here/digest.sh\" save   (lines on standard input)"
