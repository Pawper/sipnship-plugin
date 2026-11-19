#!/bin/sh
# Put the drive's round model into the scheduled task's own file, so a builder
# never picks it by hand: reads roundModel from .claude/project-drive.json and
# sets the `model:` line in the task file. Prints what it did; changes nothing
# when roundModel is empty. With --check, writes nothing and says whether the
# file names the model the settings name.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/round-model.sh" [--check] TASK_FILE
here=$(dirname "$0")
. "$here/round-model-lib.sh"
check=no
[ "${1:-}" = "--check" ] && { check=yes; shift; }
file=${1:-}
[ -n "$file" ] && [ -f "$file" ] || { echo "no task file given or found: say where the scheduled task's file is"; exit 2; }
settings=.claude/project-drive.json
model=
[ -f "$settings" ] && model=$(sed -n 's/.*"roundModel"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$settings" | head -n 1)
if [ -z "$model" ]; then echo "no roundModel in $settings: the round keeps the app's default model"; exit 0; fi
text=$(cat "$file")
if [ "$check" = yes ]; then
  r=$(round_model_check "$text" "$model")
  if [ "$r" = ok ]; then echo "ok: the task runs on $model"; else echo "$r; the settings name $model"; fi
  exit 0
fi
printf '%s\n' "$(round_model_set "$text" "$model")" > "$file"
echo "set: the scheduled task now runs on $model"
