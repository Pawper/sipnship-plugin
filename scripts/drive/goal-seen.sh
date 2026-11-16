#!/bin/sh
# Record that the drive declined a goal (mark-waiting, ask-fix or ask-owner) after a reader looked at
# the issue, so the plan does not propose it again on every tick: it becomes a hold until the issue
# changes (quiet_declined_goals in ask-gate-lib.sh reads the note).
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/goal-seen.sh" KIND ISSUE
# Appends "KIND<TAB>ISSUE<TAB>UPDATED_AT" to .scratch/drive/declined.tsv. One REST call for the issue's updated time.
case "${1:-}" in mark-waiting|ask-fix|ask-owner) ;; *) echo "usage: goal-seen.sh mark-waiting|ask-fix|ask-owner ISSUE" >&2; exit 1 ;; esac
case "${2:-}" in ''|*[!0-9]*) echo "usage: goal-seen.sh KIND ISSUE" >&2; exit 1 ;; esac
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || { echo "gh is not available or not signed in" >&2; exit 1; }
updated=$(gh api "repos/{owner}/{repo}/issues/$2" --jq .updated_at 2>/dev/null | tr -d '\r')
[ -n "$updated" ] || { echo "could not read issue $2" >&2; exit 1; }
mkdir -p .scratch/drive
printf '%s\t%s\t%s\n' "$1" "$2" "$updated" >> .scratch/drive/declined.tsv
echo "$1 $2 is a hold until the issue changes"
