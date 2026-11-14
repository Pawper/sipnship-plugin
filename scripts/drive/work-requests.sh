#!/bin/sh
# Read the Work tab's requests the drive still owes. Read-only: one line per
# request, "start-next N by LOGIN" or "hold-agent N by LOGIN", or nothing.
# Each is a person's word on the drive issue, so it needs no proposal and no
# reply. One REST call finds the issue; the newest two pages of comments are
# read, as approval.sh reads them. See the project-drive skill, step a.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/work-requests.sh"
here=$(dirname "$0")
. "$here/drive-lib.sh"
. "$here/auto-lib.sh"
. "$here/round-lib.sh"
. "$here/comment-lib.sh"

command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || exit 0
drive_line=$(drive_issue_line)
auto=$(auto_drive_state "$drive_line")
case "$auto" in none|failed) exit 0 ;; esac
issue=${auto#* }
count=$(printf '%s\n' "$drive_line" | head -n 1 | cut -f3)
comments=""
for page in $(comment_pages "$count"); do
  comments="${comments}$(gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100&page=$page" --jq '.[] | [.created_at, .user.login, (.body | gsub("\t"; " ") | gsub("\r"; ""))] | @tsv' 2>/dev/null)
"
done
ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
# As long as the service waits before it says nothing came of one (core's WAIT_MS).
work_requests "$(without_bare_path_comments "$comments")" "$(ago 86400)" "$(ago 3600)"
