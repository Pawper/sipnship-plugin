#!/bin/sh
# Post a file's contents as one comment on an issue, the one way the drive
# comments from a file. It posts with -F body=@FILE (which reads the file) and
# refuses a missing or empty file and a body that is only a path.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/comment.sh" ISSUE FILE
# Prints the comment's link. Needs gh signed in; REST only.
here=$(dirname "$0")
. "$here/comment-lib.sh"
issue=${1:-}; file=${2:-}
case "$issue" in ''|*[!0-9]*) echo "usage: comment.sh ISSUE FILE" >&2; exit 1 ;; esac
[ -n "$file" ] || { echo "usage: comment.sh ISSUE FILE" >&2; exit 1; }
why=$(comment_refusal "$file")
[ -z "$why" ] || { echo "$why" >&2; exit 1; }
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || { echo "gh is not available or not signed in" >&2; exit 1; }
gh api -X POST "repos/{owner}/{repo}/issues/$issue/comments" -F "body=@$file" --jq .html_url
