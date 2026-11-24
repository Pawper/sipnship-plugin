#!/bin/sh
# Post a file's contents as one comment on an issue, the one way the drive
# comments from a file. It posts with -F body=@FILE (which reads the file) and
# refuses a missing or empty file and a body that is only a path.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/comment.sh" ISSUE FILE
# Prints the comment's link. Needs gh signed in; REST only.
#
# When ISSUE is one of the project's three standing logs (drive, audit,
# queue), the comment goes through log_post instead (#2319), so it posts
# through the service as the app where this project is connected, and the
# builder is not its email's author for it. Every other issue (an ask, an
# instruction, a settle note) goes through note_post (#2486): through the
# service as the app, marked with the agent, naming no one, where the project is
# connected; with the one plain gh call where it is not or the service refuses.
here=$(dirname "$0")
. "$here/comment-lib.sh"
issue=${1:-}; file=${2:-}
case "$issue" in ''|*[!0-9]*) echo "usage: comment.sh ISSUE FILE" >&2; exit 1 ;; esac
[ -n "$file" ] || { echo "usage: comment.sh ISSUE FILE" >&2; exit 1; }
why=$(comment_refusal "$file")
[ -z "$why" ] || { echo "$why" >&2; exit 1; }
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || { echo "gh is not available or not signed in" >&2; exit 1; }
kind=$(gh api "repos/{owner}/{repo}/issues/$issue" --jq '[.labels[].name] | map(select(. == "drive" or . == "audit" or . == "queue")) | .[0] // ""' 2>/dev/null | tr -d '\r')
if [ -n "$kind" ]; then
  . "$here/log-post-lib.sh"
  log_post "$kind" "$issue" "$file"
else
  . "$here/note-post-lib.sh"
  note_post "$issue" "$file"
fi
