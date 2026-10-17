#!/bin/sh
# PreToolUse hook for Agent and Workflow: refuses a dispatch that would
# waste usage. An agent must be given a model that fits its task: haiku for
# a lookup, sonnet for routine work, opus for hard work. A workflow script
# must set a model on every agent() call. Agents inherit the session's
# effort level, which this hook reports so the dispatcher can see it.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
tool=$(json_field "$input" tool_name)
effort=${CLAUDE_EFFORT:-$(json_field "$input" level)}
[ -n "$effort" ] || effort=unknown

case "$tool" in
  Workflow)
    script=$(json_field "$input" script)
    [ -n "$script" ] || exit 0
    missing=$(workflow_model_reason "$script")
    [ -n "$missing" ] || exit 0
    printf '%s\n' "Blocked the workflow because $missing of its agent() calls set no model; give each call a model that fits its task (haiku for a lookup, sonnet for routine work, opus for hard work) so the fan-out does not run every agent on the heaviest model (session effort is $effort and every agent inherits it)." >&2
    exit 2
    ;;
  Agent)
    type=$(json_field "$input" subagent_type)
    description=$(json_field "$input" description)
    prompt=$(json_field "$input" prompt)
    model=$(json_field "$input" model)
    hit=$(agent_model_reason "$type" "$description" "$prompt" "$model")
    [ -n "$hit" ] || exit 0
    want=${hit%% *}
    tier=${hit#* }
    if [ -z "$model" ]; then
      why="no model was set"
    else
      why="model \`$model\` is heavier than it needs"
    fi
    printf '%s\n' "Blocked the agent dispatch \`${description:-$type}\` because $why for a $tier task; pass \`model: $want\` and keep the prompt to one bounded question or change (session effort is $effort and the agent inherits it, so lower it first if this is a long lookup)." >&2
    exit 2
    ;;
esac
exit 0
