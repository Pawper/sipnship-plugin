#!/bin/sh
# Record that the drive looked at an `ask-fix N` goal and could do nothing more with it now, so the
# plan does not propose it again as a numbered goal on every tick: it becomes a hold, until the
# issue changes (quiet_ask_fixes in ask-gate-lib.sh reads the note).
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/ask-fix-seen.sh" ISSUE
# Appends "ISSUE<TAB>UPDATED_AT" to .scratch/drive/ask-fix.txt. One REST call for the issue's updated time.
case "${1:-}" in ''|*[!0-9]*) echo "usage: ask-fix-seen.sh ISSUE" >&2; exit 1 ;; esac
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || { echo "gh is not available or not signed in" >&2; exit 1; }
updated=$(gh api "repos/{owner}/{repo}/issues/$1" --jq .updated_at 2>/dev/null | tr -d '\r')
[ -n "$updated" ] || { echo "could not read issue $1" >&2; exit 1; }
mkdir -p .scratch/drive
printf '%s\t%s\n' "$1" "$updated" >> .scratch/drive/ask-fix.txt
echo "ask-fix $1 is a hold until the issue changes"
