#!/bin/sh
# What publish-round.sh does once a started round is on the drive issue. Sourced
# by publish-round.sh, which kept growing past its size limit.

# set_in_progress OPEN
# OPEN is the comma separated issue numbers of the round's units that have no
# pull request. Each gets the In progress state label, over REST, and any other
# state label is taken off; one already In progress is left alone.
set_in_progress() {
  for n in $(printf '%s' "$1" | tr ',' ' '); do
    have=$(gh api "repos/{owner}/{repo}/issues/$n/labels" --jq '.[].name' 2>/dev/null)
    form="state:in-progress"
    printf '%s\n' "$have" | grep -q '^state: ' && form="state: in-progress"
    printf '%s\n' "$have" | grep -qxF "$form" && { echo "#$n: already In progress."; continue; }
    printf '%s\n' "$have" | grep -E '^state: ?' | while IFS= read -r l; do
      enc=$(printf '%s' "$l" | sed 's/:/%3A/g;s/ /%20/g')
      gh api -X DELETE "repos/{owner}/{repo}/issues/$n/labels/$enc" >/dev/null 2>&1
    done
    if gh api -X POST "repos/{owner}/{repo}/issues/$n/labels" -f "labels[]=$form" >/dev/null 2>&1; then echo "#$n: set to In progress."; else echo "#$n: could not set In progress; set it with scripts/state.sh."; fi
  done
}
