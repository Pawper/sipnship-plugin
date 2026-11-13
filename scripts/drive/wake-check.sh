#!/bin/sh
# Decide whether a woken run should start a drive tick: read the approval
# (approval.sh) and the Work tab requests still owed (work-requests.sh), both
# read-only and with no model, and print "start: ..." or "nothing: why".
# With GITHUB_OUTPUT set (a workflow step), also writes start=yes or start=no
# and the reason, so the model step runs only when something is approved.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/wake-check.sh"
here=$(dirname "$0")
. "$here/wake-lib.sh"
out=$(sh "$here/approval.sh" 2>&1)
req=$(sh "$here/work-requests.sh" 2>/dev/null)
d=$(wake_decision "$out" "$req")
kind=$(printf '%s' "$d" | cut -f1)
why=$(printf '%s' "$d" | cut -f2)
if [ "$kind" = start ]; then echo "start: $why"; else echo "nothing: $why"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  if [ "$kind" = start ]; then echo "start=yes" >> "$GITHUB_OUTPUT"; else echo "start=no" >> "$GITHUB_OUTPUT"; fi
  echo "why=$why" >> "$GITHUB_OUTPUT"
fi
exit 0
