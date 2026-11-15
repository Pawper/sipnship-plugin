#!/bin/sh
# Which model a dispatched agent needs: the task's tier and the rule that refuses a
# heavier model than the tier calls for. Sourced by require-agent-model.sh and the
# plugin's tests, after lib.sh (json_field and the rest). Kept apart from lib.sh,
# which is over its size limit.

# task_tier SUBAGENT_TYPE DESCRIPTION PROMPT: lookup (finds, lists or reads; short prompt), hard (designs, implements, debugs, reviews, plans) or routine.
task_tier() {
  tt_type=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  tt_text=$(printf '%s %s' "$2" "$3" | tr 'A-Z' 'a-z')
  tt_words=$(printf '%s' "$3" | wc -w | tr -d ' ')
  case "$tt_type" in
    explore|claude-code-guide) echo lookup; return 0 ;;
    plan) echo hard; return 0 ;;
  esac
  if printf '%s' "$tt_text" | grep -Eq '(design|architect|refactor|implement|build|debug|fix|review|audit|security|prove|migrat|plan)'; then
    echo hard
    return 0
  fi
  # A prompt naming a brief to follow, a worktree or a pull request is a unit of work, never a lookup, whatever its length.
  if printf '%s' "$tt_text" | grep -Eq '(worktree|pull request|open a pr|(on|your|its|new) branch|your (full )?brief|the brief|brief file|\.scratch/)'; then echo routine; return 0; fi
  # So is one that names an issue and a branch, or a round's unit and its area, as the drive's briefs do: the words of its title (a tip, a lookup) never decide.
  if printf '%s' "$tt_text" | grep -Eq '(issue[ -]?#?[0-9]+|#[0-9]{2,})' && printf '%s' "$tt_text" | grep -Eq '(branch|area|round|unit|brief)'; then echo routine; return 0; fi
  if [ "$tt_words" -le 120 ] && printf '%s' "$tt_text" | grep -Eq '(find|search|locate|list|grep|where is|look up|lookup|which file|read|check whether|does .* exist|count)'; then
    echo lookup
    return 0
  fi
  echo routine
}

# model_rank MODEL
# Print 1 for haiku, 2 for sonnet, 3 for opus, 4 for fable, 0 for unknown.
model_rank() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    *haiku*) echo 1 ;;
    *sonnet*) echo 2 ;;
    *opus*) echo 3 ;;
    *fable*|*mythos*) echo 4 ;;
    *) echo 0 ;;
  esac
}

# agent_model_reason SUBAGENT_TYPE DESCRIPTION PROMPT MODEL
# Print "MODEL_TO_USE TIER" when a dispatch would waste usage: no model was
# set, or the model is heavier than the task's tier needs. Print nothing when
# the dispatch is fine. A lighter model than the tier suggests is allowed.
agent_model_reason() {
  am_tier=$(task_tier "$1" "$2" "$3")
  case "$am_tier" in
    lookup) am_want=haiku; am_rank=1 ;;
    routine) am_want=sonnet; am_rank=2 ;;
    *) am_want=opus; am_rank=3 ;;
  esac
  if [ -z "$4" ]; then
    printf '%s %s\n' "$am_want" "$am_tier"
    return 0
  fi
  if [ "$(model_rank "$4")" -gt "$am_rank" ]; then
    printf '%s %s\n' "$am_want" "$am_tier"
  fi
}
