#!/bin/sh
# Make the state label, the board's State field and the built-in Status
# agree for every issue. The label is the source of truth when it exists;
# otherwise the board's State is. An issue with neither is left for the
# audit to report. Closed issues get Status Done.
# Usage: sh scripts/board-sync.sh PROJECT_NUMBER OWNER [--dry-run]
# Needs gh signed in with the project scope: gh auth refresh -s project
set -e
project=$1
owner=$2
dry=$3
[ -n "$project" ] && [ -n "$owner" ] || { echo "Usage: sh scripts/board-sync.sh PROJECT_NUMBER OWNER [--dry-run]" >&2; exit 2; }

here=$(dirname "$0")
. "$here/board-lib.sh"

board_load "$project" "$owner"

# Board items first: number, State value, Status value, closed or not.
items=$(gh_project item-list "$project" --owner "$owner" --limit 1000 --format json \
  --jq '.items[] | select(.content.type == "Issue") | "\(.content.number)\t\(.state // "")\t\(.status // "")"')

# Then every issue in the repository, open and closed, with its labels.
issues=$(gh issue list --state all --limit 1000 --json number,state,labels \
  --jq '.[] | "\(.number)\t\(.state)\t\([.labels[].name] | join(","))"')

changed=0
skipped=0
printf '%s\n' "$issues" | while IFS="$(printf '\t')" read -r number ghstate labels; do
  [ -n "$number" ] || continue
  closed=false
  [ "$ghstate" = "CLOSED" ] && closed=true
  label=$(state_label_in "$labels")
  board_state=$(printf '%s\n' "$items" | awk -F'\t' -v n="$number" '$1 == n { print $2; exit }')
  board_status=$(printf '%s\n' "$items" | awk -F'\t' -v n="$number" '$1 == n { print $3; exit }')
  if [ -n "$label" ]; then
    want=$(state_name_from_label "$label")
  elif [ -n "$board_state" ]; then
    want=$board_state
  else
    echo "issue $number: no state anywhere; left for the audit"
    continue
  fi
  want_status=$(status_for "$want" "$closed")
  want_label=$(label_from_state_name "$want")
  if [ "$label" = "$want_label" ] && [ "$(printf '%s' "$board_state" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$want" | tr 'A-Z' 'a-z')" ] && [ "$board_status" = "$want_status" ]; then
    continue
  fi
  if [ "$dry" = "--dry-run" ]; then
    echo "issue $number: would set $want_label, State = $want, Status = $want_status"
  else
    board_apply "$number" "$want" "$closed"
  fi
done
echo "sync finished"
