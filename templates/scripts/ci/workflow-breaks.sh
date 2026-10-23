#!/bin/sh
# Say when a workflow that passed before its last change on main has
# failed every run since: a template sync once broke a project's nightly
# audit and nothing said so for two days. One line per such workflow,
# nothing when all is well. The session brief and the nightly audit both
# run it, so they never disagree.
#
# Usage: sh scripts/ci/workflow-breaks.sh [BASE]
# Reads the last change of every plugin-owned workflow from git (origin/BASE
# as fetched, default main; one local call each) and the newest hundred
# runs in one REST call.
here=$(dirname "$0")
. "$here/lib.sh"
base=${1:-main}
command -v gh >/dev/null 2>&1 || exit 0
changes=""
for wf in .github/workflows/*.yml; do
  [ -f "$wf" ] || continue
  c=$(git log -1 --first-parent --format='%ct%x09%cs%x09%s' "origin/$base" -- "$wf" 2>/dev/null | tr -d '\r')
  [ -n "$c" ] || continue
  changes="$changes$wf	$c
"
done
[ -n "$changes" ] || exit 0
runs=$(gh api "repos/{owner}/{repo}/actions/runs?per_page=100" \
  --jq '.workflow_runs[] | select(.status == "completed") | "\(.path)\t\(.conclusion // "")\t\(.created_at)"' 2>/dev/null | tr -d '\r' \
  | while IFS="	" read -r r_path r_conc r_at; do
      r_epoch=$(date -u -d "$r_at" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$r_at" +%s 2>/dev/null || echo 0)
      printf '%s\t%s\t%s\n' "$r_path" "$r_conc" "$r_epoch"
    done)
workflow_breaks "$runs" "$changes"
