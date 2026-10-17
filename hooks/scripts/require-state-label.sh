#!/bin/sh
# PreToolUse hook for Bash: refuses `gh issue create` without a State label.
# The rule it enforces: every issue carries its state from the moment it is
# filed, so the board and the audits can trust the label.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0

# A project that keeps state as a field on its GitHub Project says so in
# .claude/issue-state.txt ("project"); there the rule is --project instead.
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
mode=$(head -n 1 "$root/.claude/issue-state.txt" 2>/dev/null | tr -d '\r ')
if [ "$mode" = project ]; then
  hit=$(project_flag_reason "$cmd")
  [ -n "$hit" ] || exit 0
  printf '%s
' "Blocked \`$hit\` because every issue goes on the project board at filing, where its state is set; add \`--project \"<board title>\"\` and set its Status, then run it again." >&2
  exit 2
fi

hit=$(state_label_reason "$cmd")
[ -n "$hit" ] || exit 0

printf '%s\n' "Blocked \`$hit\` because every issue needs a State label at filing; add \`--label state:ready\` (or state:in-progress, state:waiting-on-owner, state:waiting-on-service, state:parked, state:dated, state:after-launch) and run it again." >&2
exit 2
