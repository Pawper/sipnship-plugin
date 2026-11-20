#!/bin/sh
# For the nightly audit: a missed publish is a fault that is seen (#2101). The
# drive's plan publishes its proposed round to the Work tab every time it
# looks; when the latest proposed round on the issue labeled drive is older
# than MINUTES (default 60) while ready work waits, the drive has stopped
# looking or stopped publishing, and this says so in one line. A round
# carries when the drive looked ("looked" in its marker); one without it is
# dated by its comment. REST only, three calls; prints nothing when all is
# well, when the project has no drive issue, or when GitHub cannot be asked.
# Needs GH_REPO. NOW (epoch seconds) is for tests.
repo=${GH_REPO:-}
[ -n "$repo" ] || exit 0
minutes=${1:-60}
now=${NOW:-$(date +%s)}
drive=$(gh api "repos/$repo/issues?labels=drive&state=open&per_page=1" --jq '.[0] // empty | [(.number | tostring), (.comments | tostring)] | @tsv' 2>/dev/null | tr -d '\r' | head -n 1)
[ -n "$drive" ] || exit 0
issue=$(printf '%s' "$drive" | cut -f1); count=$(printf '%s' "$drive" | cut -f2)
ready=$(gh api "repos/$repo/issues?state=open&labels=state:ready&per_page=100" --jq '[.[] | select(.pull_request | not)] | length' 2>/dev/null | tr -d '\r')
spaced=$(gh api "repos/$repo/issues?state=open&labels=state:%20ready&per_page=100" --jq '[.[] | select(.pull_request | not)] | length' 2>/dev/null | tr -d '\r')
ready=$(( ${ready:-0} + ${spaced:-0} ))
[ "$ready" -gt 0 ] || exit 0
page=$(( (${count:-0} + 99) / 100 )); [ "$page" -ge 1 ] || page=1
last=$(gh api "repos/$repo/issues/$issue/comments?per_page=100&page=$page" --jq '.[] | select(.body | contains("sipnship-proposal {")) | select(.body | contains("\"status\":\"started\"") | not) | [(.created_at | fromdateiso8601 | tostring), (([.body | capture("\"looked\":\"(?<l>[^\"]+)\"")] | .[0].l) // "")] | @tsv' 2>/dev/null | tr -d '\r' | tail -n 1)
at=$(printf '%s' "$last" | cut -f1)
looked=$(printf '%s' "$last" | cut -f2)
if [ -n "$looked" ]; then l=$(date -d "$looked" +%s 2>/dev/null) && at=$l; fi
if [ -z "$at" ]; then
  printf 'Your drive has never published a proposed round on #%s, while %s ready issue(s) wait; run the plan (scripts/drive/plan.sh), which publishes it.\n' "$issue" "$ready"
  exit 0
fi
age=$(( (now - at) / 60 ))
[ "$age" -ge "$minutes" ] || exit 0
if [ "$age" -ge 120 ]; then said="$(( age / 60 )) hours"; else said="$age minutes"; fi
printf 'The proposed round on #%s is %s old while %s ready issue(s) wait: the drive has not looked, or looked and did not publish. Its round report says why on a "not published:" line.\n' "$issue" "$said" "$ready"
exit 0
