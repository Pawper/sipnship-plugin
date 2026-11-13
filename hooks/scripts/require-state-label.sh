#!/bin/sh
# PreToolUse hook for Bash: refuses `gh issue create` without a State label.
# The rule it enforces: every issue carries its state from the moment it is
# filed, so the board and the audits can trust the label.
# It holds a second rule: a decision gives choices and recommends exactly one.
# Setting an issue to waiting on the owner is refused while the ask it was just
# left with gives choices and none, or more than one, is recommended, is a
# question with no choices at all, or is a step the owner does outside the app
# dressed as a choice between doing it and setting it aside. A comment that
# starts "Instructions:" is steps, not a decision, and passes without choices.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"
. "$here/rule-switch.sh"
asks=no
if [ -f "$here/../../templates/scripts/ci/ask-lib.sh" ]; then
  . "$here/../../templates/scripts/ci/ask-lib.sh"
  . "$here/ask-hook-lib.sh"
  asks=yes
fi

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0

waiting=""
[ "$asks" = no ] || waiting=$(waiting_on_owner_issue "$cmd")
if [ -n "$waiting" ] && rule_on ask-recommends-one; then
  fix=$(ask_fix "$(ask_of_issue "$waiting")")
  if [ -n "$fix" ]; then
    printf '%s\n' "Blocked setting #$waiting to waiting on the owner, because $fix. Edit that comment (or post the ask again, fixed), then set the state again. The project-drive skill's \"How to write an ask\" shows the shape." >&2
    exit 2
  fi
elif [ -n "$waiting" ]; then
  [ -z "$(ask_fix "$(ask_of_issue "$waiting")")" ] || rule_off_note ask-recommends-one
fi

# A project that keeps state as a field on its GitHub Project says so in
# .claude/issue-state.txt ("project"); there the rule is --project instead.
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
mode=$(head -n 1 "$root/.claude/issue-state.txt" 2>/dev/null | tr -d '\r ')
if [ "$mode" = project ]; then
  hit=$(project_flag_reason "$cmd")
  [ -z "$hit" ] || rule_gate issue-has-state
  [ -n "$hit" ] || exit 0
  printf '%s
' "Blocked \`$hit\` because every issue goes on the project board at filing, where its state is set; add \`--project \"<board title>\"\` and set its Status, then run it again." >&2
  exit 2
fi

hit=$(state_label_reason "$cmd")
[ -z "$hit" ] || rule_gate issue-has-state
[ -n "$hit" ] || exit 0

printf '%s\n' "Blocked \`$hit\` because every issue needs a State label at filing; add \`--label state:ready\` (or state:in-progress, state:waiting-on-owner, state:waiting-on-service, state:parked, state:dated, state:after-launch) and run it again." >&2
exit 2
