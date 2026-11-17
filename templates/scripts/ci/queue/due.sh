#!/bin/sh
# Is a drain owed? Run by queue-drain.yml on its frequent schedule, after the
# checkout; reads a few facts with REST, asks drain_due_reason, and says so in
# the step's output (skip=yes when none is owed). Any other kind of run is
# never skipped here. Never fatal: a fact that cannot be read leaves a drain
# owed only when another fact says so.
#
# Usage: sh scripts/ci/queue/due.sh   (GH_TOKEN, GH_REPO, GITHUB_EVENT_NAME,
# DUE_FREQUENT=yes, GITHUB_RUN_ID, GITHUB_OUTPUT)
here=$(cd "$(dirname "$0")" && pwd)
. "$here/rules-due.sh"
out=${GITHUB_OUTPUT:-/dev/null}
if [ "${DUE_FREQUENT:-}" != yes ]; then exit 0; fi

now=$(date +%s)
wf="repos/$GH_REPO/actions/workflows/queue-drain.yml/runs"
runs=$(gh api "$wf?per_page=20" --jq '.workflow_runs[] | [.id, .status, (.conclusion // ""), .updated_at] | @tsv' 2>/dev/null | tr -d '\r')
active=$(printf '%s\n' "$runs" | awk -F'\t' -v me="${GITHUB_RUN_ID:-0}" '$1 != me && ($2 == "queued" || $2 == "in_progress" || $2 == "waiting" || $2 == "pending") { n++ } END { print n + 0 }')
last=$(printf '%s\n' "$runs" | awk -F'\t' -v me="${GITHUB_RUN_ID:-0}" '$1 != me && $2 == "completed" { print $3 "\t" $4; exit }')
last_c=$(printf '%s' "$last" | cut -f1)
last_at=$(printf '%s' "$last" | cut -f2)
last_age=0
[ -z "$last_at" ] || last_age=$(( now - $(date -u -d "$last_at" +%s 2>/dev/null || echo "$now") ))

lock=no
gh api "repos/$GH_REPO/git/ref/queue/lock" >/dev/null 2>&1 && lock=yes

body=$(gh api "repos/$GH_REPO/issues?state=open&per_page=100" --jq '[.[] | select(.title == "Merge queue")][0].body // ""' 2>/dev/null | tr -d '\r')
mode=$(printf '%s' "$body" | grep -o '"mode":"[a-z]*"' | head -n 1 | sed 's/.*:"\(.*\)"/\1/')
stamp=$(printf '%s' "$body" | grep -o '"updatedAt":"[^"]*"' | head -n 1 | sed 's/.*:"\(.*\)"/\1/')
since=0
[ -z "$stamp" ] || since=$(( now - $(date -u -d "$stamp" +%s 2>/dev/null || echo "$now") ))

facts=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$lock" "$active" "$last_c" "$last_age" "$mode" "$(drain_due_hold "$body")" "$(drain_due_green "$body")" "$since" "$now")
why=$(drain_due_reason "$facts")
if [ -n "$why" ]; then
  echo "A drain is owed: $why."
else
  echo "No drain is owed; ending here."
  echo "skip=yes" >> "$out"
fi
exit 0
