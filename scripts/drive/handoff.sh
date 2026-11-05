#!/bin/sh
# The handoff of a coordinator session, as one comment on the drive issue.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/handoff.sh" last
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/handoff.sh" post FILE [--issue N]
#
# A handoff is a comment whose first line starts with the word "Handoff".
# last prints the newest one as "epoch<TAB>url", or nothing; post writes
# FILE as a comment and prints its link, and refuses a file whose first line
# does not start with that word, since the brief finds it by that line.
# Everything here is REST. Needs gh signed in.
here=$(dirname "$0")
. "$here/drive-lib.sh"
. "$here/round-lib.sh"
cmd=${1:-}; shift 2>/dev/null
file=""; issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue=$2; shift 2 ;;
    *) file=$1; shift ;;
  esac
done
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || { echo "gh is not available or not signed in" >&2; exit 1; }

drive_line=$(gh api "$AUTO_DRIVE_QUERY" --jq "$AUTO_DRIVE_JQ" 2>/dev/null | tr -d '\r')
auto=$(auto_drive_state "$drive_line")
[ -n "$issue" ] || { [ "$auto" = none ] || issue=${auto#* }; }

case "$cmd" in
  last)
    [ -n "$issue" ] || exit 0
    count=$(printf '%s\n' "$drive_line" | head -n 1 | cut -f3)
    for page in $(comment_pages "$count"); do
      gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100&page=$page" \
        --jq '.[] | select(.body | test("^Handoff")) | [(.created_at | fromdateiso8601 | tostring), .html_url] | @tsv' 2>/dev/null
    done | tr -d '\r' | sort -n | tail -n 1
    ;;
  post)
    [ -f "$file" ] || { echo "post needs the file holding the handoff" >&2; exit 1; }
    case "$(head -n 1 "$file" | tr -d '\r')" in
      Handoff*) ;;
      *) echo "The handoff's first line must start with the word Handoff, so the next session finds it." >&2; exit 1 ;;
    esac
    [ -n "$issue" ] || { echo "No open issue is labeled drive. Pass --issue N to name the drive issue." >&2; exit 1; }
    gh api -X POST "repos/{owner}/{repo}/issues/$issue/comments" -F "body=@$file" --jq .html_url
    ;;
  *) echo "usage: handoff.sh last | post FILE [--issue N]" >&2; exit 1 ;;
esac
