#!/bin/sh
# PreToolUse hook for Bash: blocks commands that delete files.
# The rule it enforces: never delete; move aside.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0

hit=$(delete_reason "$cmd")
[ -n "$hit" ] || exit 0

printf '%s\n' "Blocked \`$hit\` because this project never deletes files; move them aside instead, for example \`git mv path aside/path\` or \`mv path path.aside\`." >&2
exit 2
