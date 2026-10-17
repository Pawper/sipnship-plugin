#!/bin/sh
# Set an issue's state in one go: the state label, the board's State field,
# and the mirrored built-in Status. Use it when filing and whenever the
# state changes, so the three never disagree.
# Usage: sh scripts/state.sh PROJECT_NUMBER OWNER ISSUE_NUMBER "Ready"
# Needs gh signed in with the project scope: gh auth refresh -s project
set -e
project=$1
owner=$2
issue=$3
state=$4
[ -n "$project" ] && [ -n "$owner" ] && [ -n "$issue" ] && [ -n "$state" ] || {
  echo 'Usage: sh scripts/state.sh PROJECT_NUMBER OWNER ISSUE_NUMBER "Ready"' >&2; exit 2; }

here=$(dirname "$0")
. "$here/board-lib.sh"

# The label is REST and always lands. The board is GraphQL; when GitHub
# refuses it (the secondary limit, which gh reports as "unknown owner
# type"), say so in one line and let the nightly sync set the field.
closed=$(gh api "repos/{owner}/{repo}/issues/$issue" --jq '.state == "closed"')
if board_load "$project" "$owner" 2>"${TMPDIR:-/tmp}/state.$$.err"; then
  board_apply "$issue" "$state" "$closed" || echo "issue $issue: the label is set; the board's State is pending. The nightly board sync sets it."
else
  issue_set_state_label "$issue" "$(label_from_state_name "$state")"
  if [ "$(board_refusal "$(cat "${TMPDIR:-/tmp}/state.$$.err" 2>/dev/null)")" = yes ]; then
    echo "Set the label on #$issue. The board's State was not set: GitHub refused the board call for its rate limit. The nightly board sync will set it; nothing else to do."
  else
    echo "Set the label on #$issue. The board's State was not set:" >&2; cat "${TMPDIR:-/tmp}/state.$$.err" >&2
  fi
fi
rm -f "${TMPDIR:-/tmp}/state.$$.err" 2>/dev/null
