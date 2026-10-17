#!/bin/sh
# PreToolUse hook for Bash: blocks any forced git push.
# The rule it enforces: never force-push; history on a shared branch stays.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0

hit=$(force_push_reason "$cmd")
[ -n "$hit" ] || exit 0

printf '%s\n' "Blocked the forced push (\`$hit\`) because shared history is never rewritten; push a new commit on top, or start a new branch if this one is wrong." >&2
exit 2
