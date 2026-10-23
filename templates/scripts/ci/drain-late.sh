#!/bin/sh
# Say when the scheduled queue drain is late: GitHub fires a schedule late
# or skips it, and a green pull request then waits most of a day unseen.
# One line, nothing when on time, when the workflow is absent or when it has
# never run. The session brief and the nightly audit both run it.
#
# Usage: sh scripts/ci/drain-late.sh
# Reads the interval from the cron line (*/N hours) and the last completed
# scheduled run in one REST call.
here=$(dirname "$0")
. "$here/lib.sh"
wf=.github/workflows/queue-drain.yml
[ -f "$wf" ] || exit 0
command -v gh >/dev/null 2>&1 || exit 0
interval=$(sed -n 's/.*cron:[^"]*"[^ ]* \*\/\([0-9][0-9]*\) .*/\1/p' "$wf" | head -n 1)
[ -n "$interval" ] || exit 0
at=$(gh api "repos/{owner}/{repo}/actions/workflows/queue-drain.yml/runs?event=schedule&status=completed&per_page=1" \
  --jq '.workflow_runs[0].created_at // empty' 2>/dev/null | tr -d '\r')
[ -n "$at" ] || exit 0
last=$(date -u -d "$at" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$at" +%s 2>/dev/null || echo 0)
drain_late "$last" "$(date -u +%s)" "$interval"
