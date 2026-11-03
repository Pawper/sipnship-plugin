#!/bin/sh
# PreToolUse hook for Bash, Edit, Write and MultiEdit: the lock on the
# switches. An agent may not turn a rule off, or the safety locks, itself:
# it refuses setting the repository variables RULES_OFF and RULES_LOCKS,
# editing .claude/rules-off.txt, and running the person's own switch
# (sh scripts/rules.sh off|on). A switch is flipped by the builder, in the
# app or in their own terminal. This hook is not a rule on the list and has
# no switch of its own.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"
. "$here/rule-switch.sh"

input=$(cat)
cmd=$(json_field "$input" command)
if [ -n "$cmd" ]; then
  hit=$(rule_switch_reason "$cmd")
else
  path=$(json_field "$input" file_path)
  [ -n "$path" ] || exit 0
  hit=$(rule_switch_path_reason "$path")
fi
[ -n "$hit" ] || exit 0

printf '%s\n' "Blocked \`$hit\` because a rule's switch is the builder's to turn, never an agent's: an agent that switched its own rule off would be marking its own work. If a rule is in your way, say which and why in your report, and the person can switch it on the Rules tab or with \`sh scripts/rules.sh off ID \"reason\"\` in their own terminal." >&2
exit 2
