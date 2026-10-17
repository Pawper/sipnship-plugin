#!/bin/sh
# One network call for the whole board. Prints tab-separated facts:
#
#   pr      NUMBER  TITLE  ROLLUP  MERGEABLE  HEAD_BRANCH  FILES(comma separated)  UPDATED_AT
#   issue   NUMBER  TITLE  LABELS(comma separated)  UPDATED_AT  BODY(first 300 characters)
#   total   ISSUES_OPEN
#
# ROLLUP is the head commit's check rollup: SUCCESS, FAILURE, ERROR,
# PENDING, EXPECTED, or NONE when there are no checks. UPDATED_AT is the
# item's last-updated time, which the board digest compares against the
# time each saved summary was written. The session brief, the drive's plan
# and the board reader all read this; none makes another call per pull
# request or per issue. Exits non-zero and prints nothing when gh is
# missing, signed out or offline, so callers can say "(unavailable)".
command -v gh >/dev/null 2>&1 || exit 1

query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
  pullRequests(states:OPEN,first:30,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{
    number title mergeable headRefName updatedAt
    commits(last:1){nodes{commit{statusCheckRollup{state}}}}
    files(first:50){nodes{path}}
  }}
  issues(states:OPEN,first:100,orderBy:{field:UPDATED_AT,direction:DESC}){totalCount nodes{
    number title updatedAt bodyText labels(first:10){nodes{name}}
  }}
}}'

gh api graphql -F owner='{owner}' -F name='{repo}' -f query="$query" --jq '
  .data.repository as $r
  | ($r.pullRequests.nodes[] | [
      "pr", .number, (.title | gsub("[\\t\\n\\r]"; " ")),
      (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"),
      .mergeable, .headRefName,
      ([.files.nodes[]?.path] | join(",")),
      .updatedAt
    ] | @tsv),
    ($r.issues.nodes[] | [
      "issue", .number, (.title | gsub("[\\t\\n\\r]"; " ")),
      ([.labels.nodes[].name] | join(",")),
      .updatedAt,
      ((.bodyText // "")[0:300] | gsub("[\\t\\n\\r]"; " "))
    ] | @tsv),
    (["total", $r.issues.totalCount] | @tsv)
' 2>/dev/null
