#!/bin/sh
# Closed issues that still carry a State label (#2198): In progress, Ready, Waiting on owner or Blocked. A closed issue
# carries none, so this lists them and, with --apply, takes the label off, over REST, with no model. The plan takes the label off
# a closed In progress issue it meets (facts_without_closed), so it never reads as running again.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/closed-labels.sh" [--apply]
here=$(dirname "$0")
. "$here/closed-lib.sh"
apply=no; [ "${1:-}" = --apply ] && apply=yes
command -v gh >/dev/null 2>&1 || exit 0
found=$(closed_state_labels | cut -f1 | sort -un)
[ -n "$found" ] || { echo "closed: no closed issue carries a State label."; exit 0; }
count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
if [ "$apply" != yes ]; then
  echo "closed: $count closed issue(s) still carry a State label: $(printf '%s' "$found" | sed 's/^/#/' | tr '\n' ' ')"
  exit 0
fi
for n in $found; do
  labels=$(gh api "repos/{owner}/{repo}/issues/$n" --jq '.labels[].name' 2>/dev/null | tr -d '\r')
  closed_labels_json "$labels" | gh api -X PUT "repos/{owner}/{repo}/issues/$n/labels" --input - >/dev/null 2>&1 \
    && echo "closed: #$n is closed, so its State label is off." \
    || echo "closed: could not take the State label off #$n."
done
exit 0
