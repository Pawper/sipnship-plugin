#!/bin/sh
# Record that an approved goal turned out already done (the pull request
# merged by hand, the issue closed, a release already published), so
# approval.sh (drop_done_goals, done-lib.sh) never derives it as approved
# again from the same static proposal and reply, every tick after (#2052).
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/goal-done.sh" "GOAL LINE"
# GOAL LINE is the exact goal line approval.sh printed (a set-aside already
# settled by set-aside-lib.sh has its own, earlier check; this is for every
# other goal kind). Appends it to .scratch/drive/done.tsv.
[ -n "${1:-}" ] || { echo "usage: goal-done.sh \"GOAL LINE\"" >&2; exit 1; }
mkdir -p .scratch/drive
printf '%s\n' "$1" >> .scratch/drive/done.tsv
echo "dropped from the approved list, not derived again: $1"
