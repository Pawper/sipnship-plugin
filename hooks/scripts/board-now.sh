#!/bin/sh
# One network call for the whole board. Prints tab-separated facts:
#
#   pr      NUMBER  TITLE  ROLLUP  MERGEABLE  HEAD_BRANCH  FILES(comma separated)  UPDATED_AT
#   issue   NUMBER  TITLE  LABELS(comma separated)  UPDATED_AT  BODY(first 300 characters)  PATHS(comma separated)  TOUCHES
#   total   ISSUES_OPEN
#
# PATHS is every path-shaped word of the issue's whole text, so an issue written
# the usual way (what happened first, its Spec line last) is placed by a path
# past the 300th character; the plan reads it with the same rule it reads a
# body with (bundle-lib.sh body_paths), at no extra call per issue (#2273).
# TOUCHES(its first line's list) is what follows "Touches:" when the body's
# first line is one, whole however long, else empty: an issue that lists its
# files is planned from that list alone (bundle-lib.sh listed_files, #2444).
#
# ROLLUP is the head commit's check rollup: SUCCESS, FAILURE, ERROR,
# PENDING, EXPECTED, or NONE when there are no checks. UPDATED_AT is the
# item's last-updated time, which the board digest compares against the
# time each saved summary was written. The session brief, the drive's plan
# and the board reader all read this; none makes another call per pull
# request or per issue. Exits non-zero and prints nothing when gh is
# missing, signed out or offline, so callers can say "(unavailable)".
#
# A token that may not read check results (a fine-grained token cannot be
# given the Checks permission) is refused for that one field. The board is
# then read again without it and each pull request's checks come from the
# Actions runs and commit statuses (board-checks-lib.sh), so the board never
# fails for one refused field; a line on stderr says so.
command -v gh >/dev/null 2>&1 || exit 1
here_bn=$(dirname "$0")
. "$here_bn/board-checks-lib.sh"

# board_query COMMIT_FIELD: the query, with the field read from the head commit.
board_query() {
  printf '%s' 'query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
  pullRequests(states:OPEN,first:30,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{
    number title mergeable headRefName updatedAt
    commits(last:1){nodes{commit{'"$1"'}}}
    files(first:50){nodes{path}}
  }}
  issues(states:OPEN,first:100,orderBy:{field:UPDATED_AT,direction:DESC}){totalCount nodes{
    number title updatedAt bodyText labels(first:10){nodes{name}}
  }}
}}'
}

# board_read COMMIT_FIELD: the facts; the fourth field of a pull request is its
# rollup, or its head commit's oid when the rollup was not asked for.
board_read() {
  gh api graphql -F owner='{owner}' -F name='{repo}' -f query="$(board_query "$1")" --jq '
  .data.repository as $r
  | ($r.pullRequests.nodes[] | [
      "pr", .number, (.title | gsub("[\\t\\n\\r]"; " ")),
      (.commits.nodes[0].commit | (.statusCheckRollup.state // .oid // "NONE")),
      .mergeable, .headRefName,
      ([.files.nodes[]?.path] | join(",")),
      .updatedAt
    ] | @tsv),
    ($r.issues.nodes[] | [
      "issue", .number, (.title | gsub("[\\t\\n\\r]"; " ")),
      ([.labels.nodes[].name] | join(",")),
      .updatedAt,
      ((.bodyText // "")[0:300] | gsub("[\\t\\n\\r]"; " ")),
      ([(.bodyText // "") | gsub("[^A-Za-z0-9_.*/-]+"; " ") | split(" ")[] | select(test("/") and (test("//") | not) and (test("^[#/]") | not))] | unique | join(",") | .[0:1500]),
      ((.bodyText // "") | split("\n")[0] | if test("^[ ]*Touches:") then (sub("^[ ]*Touches:[ ]*"; "") | gsub("[\\t\\r]"; " ") | .[0:1500]) else "" end)
    ] | @tsv),
    (["total", $r.issues.totalCount] | @tsv)
'
}

bn_err=$(mktemp); trap 'rm -f "$bn_err"' EXIT
if bn_out=$(board_read 'statusCheckRollup{state}' 2>"$bn_err"); then
  printf '%s\n' "$bn_out"
elif [ "$(token_refusal "$(cat "$bn_err")")" = yes ]; then
  echo "this token can't read check results; the checks are read from the Actions runs and commit statuses instead" >&2
  bn_out=$(board_read 'oid' 2>"$bn_err") || { cat "$bn_err" >&2; exit 1; }
  pr_rollups "$bn_out"
else
  cat "$bn_err" >&2
  exit 1
fi
