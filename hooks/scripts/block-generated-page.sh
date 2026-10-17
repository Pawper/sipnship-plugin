#!/bin/sh
# PreToolUse hook for Edit, Write and MultiEdit: blocks a direct edit to a
# generated page. The rule it enforces: a generated page is built from stubs,
# so a hand edit is lost on the next build and collides with every other agent.
#
# The list of generated pages is read from .claude/generated-pages.txt in the
# project, one shell glob per line. When that file is missing the list is
# just STATUS.md.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
path=$(json_field "$input" file_path)
[ -n "$path" ] || exit 0

root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
list_file="$root/.claude/generated-pages.txt"
if [ -f "$list_file" ]; then
  patterns=$(cat "$list_file")
else
  patterns="STATUS.md"
fi

hit=$(generated_page_reason "$path" "$root" "$patterns")
[ -n "$hit" ] || exit 0

printf '%s\n' "Blocked a direct edit to \`$hit\` because it is a generated page; change the stub it is built from and run the build script instead (for STATUS.md that is a stub under status/stubs/ and \`sh status/build.sh\`)." >&2
exit 2
