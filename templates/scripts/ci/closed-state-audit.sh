#!/bin/sh
# For the nightly audit: every closed issue that still carries a State label,
# one line each, "#N still carries state:in-progress though it is closed."
# Closed is what says an issue is done, so a State beside it is a second
# answer that goes stale: a closed issue still marked In progress had the
# drive reading it as running work, and one still Ready had it proposing work
# already finished. Closing takes the label off in the same step, and this
# names any left behind by a close that missed it (a close from the web, a
# refused write, a project with no service connected).
#
# Only the four States that say work is outstanding are looked for: Parked,
# Dated and After launch are a closed issue's own record and are left alone.
# REST only, one call per label; prints nothing when all is well or GitHub
# cannot be asked. Needs GH_REPO.
repo=${GH_REPO:-}
[ -n "$repo" ] || exit 0
# Both forms a project may name its labels in ("state:ready" and "state: ready").
for label in "state:in-progress" "state:ready" "state:waiting-on-owner" "state:blocked" \
             "state: in progress" "state: ready" "state: waiting on owner" "state: blocked"; do
  numbers=$(gh api -X GET "repos/$repo/issues" -f state=closed -f labels="$label" -f per_page=100 \
    --jq '.[] | select(.pull_request | not) | .number' 2>/dev/null | tr -d '\r') || continue
  for n in $numbers; do
    printf '#%s still carries %s though it is closed.\n' "$n" "$label"
  done
done
exit 0
