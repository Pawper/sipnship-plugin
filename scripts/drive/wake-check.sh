#!/bin/sh
# Decide whether a woken run should start a drive tick. First the plan runs
# (plan.sh --fast), which publishes its proposed round to the Work tab by
# itself, so every look, timed or woken, leaves the tab a fresh round or says
# it could not (#2101); its output is kept in .scratch/drive/plan.txt for the
# tick. Then the approval (approval.sh) and the Work tab requests still owed
# (work-requests.sh) are read, all with no model, and it prints the plan's
# "published:" or "not published:" line, then "start: ..." or "nothing: why".
# Reading the approval after the publish is what lets the run that proposes
# also start, with Auto Drive on and no round running.
# With GITHUB_OUTPUT set (a workflow step), also writes start=yes or start=no
# and the reason, so the model step runs only when something is approved.
# WAKE_PLAN names another plan script (the suite's stand-in).
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/wake-check.sh"
here=$(dirname "$0")
. "$here/wake-lib.sh"
mkdir -p .scratch/drive 2>/dev/null
sh "${WAKE_PLAN:-$here/plan.sh}" --fast > .scratch/drive/plan.txt 2>/dev/null
pub=$(grep -E '^(published|not published):' .scratch/drive/plan.txt | tail -n 1)
echo "${pub:-not published: the plan printed no proposal, so the Work tab still shows the last round it was given.}"
out=$(sh "$here/approval.sh" 2>&1)
# Goals approved from an older posted proposal that the plan no longer prints start nothing, and the tick says so (#2104).
stale=$(approved_not_planned "$(cat .scratch/drive/plan.txt 2>/dev/null)" "$out")
if [ -n "$stale" ]; then
  out=$(printf '%s\n' "$out" | awk -F'\t' -v s="$stale" 'BEGIN { n = split(s, a, "\n"); for (i = 1; i <= n; i++) bad[a[i]] = 1 } { k = $1; sub(/^dispatch /, "", k); gsub(/ +$/, "", k) } $1 ~ /^dispatch [0-9]/ && (k in bad) { next } { print }')
  out="nothing: the approval names goals the plan no longer prints (#$(printf '%s' "$stale" | tr '\n' ' ' | sed 's/ $//; s/ /, #/g')); none of them is started
$out"
fi
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
