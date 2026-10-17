#!/bin/sh
# PreToolUse hook for Bash: blocks a bare test command that would run the
# whole suite. The rule it enforces: tests run per file on a PR; the full
# suite is the gate on main, run by CI.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0

hit=$(full_sweep_reason "$cmd")
[ -n "$hit" ] || exit 0

case "$hit" in
  npm*|yarn*|pnpm*|bun*) example="$hit -- path/to/one_test" ;;
  *) example="$hit path/to/one_test" ;;
esac
printf '%s\n' "Blocked the full test sweep \`$hit\` because it names no test file, and the whole suite runs on main in CI; name the file for the change you made, for example \`$example\` (any .test or .spec file in .ts, .tsx, .js, .jsx, .mjs or .cjs is fine, as is a -k, -t or --filter pattern)." >&2
exit 2
