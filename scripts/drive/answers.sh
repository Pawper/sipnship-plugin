#!/bin/sh
# Read the builder's answers to what was asked, each once. One line per new
# answer, "answer #N choice K by LOGIN (comment ID)", or nothing. Read-only on
# GitHub: three REST calls at most, the open issues touched in the last day
# and the comments of that day, never one call per issue. The comment ids it
# has printed are kept with the machine's own SipNShip files, never in the
# project, so a tick reads an answer once; --all prints every answer still
# owed, read before or not, and keeps nothing. See the project-drive skill,
# step a.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/answers.sh" [--all]
here=$(dirname "$0")
. "$here/answers-lib.sh"
. "$here/comment-lib.sh"

all=no
[ "$1" = --all ] && all=yes
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || exit 0
since=$(date -u -d "@$(( $(date +%s) - 86400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) - 86400 ))" +%Y-%m-%dT%H:%M:%SZ)
# The issues an answer can be owed on: open, and waiting on the builder or moved to Ready.
open=$(gh api "repos/{owner}/{repo}/issues?state=open&per_page=100&since=$since" \
  --jq '.[] | select([.labels[].name | ascii_downcase | test("^state: ?(waiting-on-owner|ready)$")] | any) | .number' 2>/dev/null | tr -d '\r')
[ -n "$open" ] || exit 0
# This is the slow step: GitHub lists every comment in the repository for the day, a page of 100 at a time, and a busy
# project has hundreds. It is bounded: past 90 seconds it says why and reads nothing this tick (the next tick tries again).
comments=$(if command -v timeout >/dev/null 2>&1; then t="timeout 90"; else t=""; fi
  $t gh api "repos/{owner}/{repo}/issues/comments?since=$since&per_page=100" --paginate \
  --jq '.[] | [(.id | tostring), .created_at, .user.login, (.issue_url | sub(".*/"; "")), (.body | gsub("\t"; " ") | gsub("\r"; ""))] | @tsv' 2>/dev/null)
rc=$?
[ "$rc" -ne 124 ] || { echo "answers: the day's comments (every comment in the repository, 100 a page) took over 90 seconds to list; no answers read this tick" >&2; exit 0; }
owed=$(owed_answers "$(without_bare_path_comments "$comments")" "$open")
[ -n "$owed" ] || exit 0
if [ "$all" = yes ]; then printf '%s\n' "$owed"; exit 0; fi

# Kept per repository, as the session brief keeps its cache.
repo=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1-\2#p' | sed 's/\.git$//')
seen_file="${SIPNSHIP_HOME:-$HOME/.sipnship}/drive-answers/${repo:-here}.seen"
seen=""
[ -f "$seen_file" ] && seen=$(cat "$seen_file")
new=$(unseen_answers "$owed" "$seen")
[ -n "$new" ] || exit 0
printf '%s\n' "$new"
mkdir -p "$(dirname "$seen_file")" 2>/dev/null && answer_ids "$new" >> "$seen_file"
exit 0
