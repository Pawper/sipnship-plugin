#!/bin/sh
# Is a deploy due? One rule for the queue, the release workflows, --status
# and the brief: a deploy goes when no other open pull request is green
# (it lands first; one deploy carries both) and the interval in
# .claude/deploy.json has passed since the last successful Deploy run.
# Nine serial landings once each carried a --deploy flag an agent copied
# from its last command; there is no flag now, only this state.
#
# Usage: sh scripts/ci/deploy-gate.sh [--last] [BASE]
#        sh scripts/ci/deploy-gate.sh --ships FROM TO
#   --ships prints "build" when a path changed between FROM and TO ships
#   (deploy-lib.sh's ships_path, with appRoot and neverShips from
#   .claude/deploy.json), "skip" when none does; the queue asks it before
#   starting Deploy, so a scripts-only landing starts no build.
#   Prints one line, "deploy: due; ..." (exit 0) or "deploy: held, ..."
#   (exit 1). --last reads only the last deploy time, no pull request scan
#   (the brief). A project with no .claude/deploy.json gates nothing.
# In a release workflow, as its first step:
#   - id: gate
#     run: sh scripts/ci/deploy-gate.sh || echo "skip=yes" >> "$GITHUB_OUTPUT"
#   and `if: steps.gate.outputs.skip != 'yes'` on the build steps.
here=$(dirname "$0")
. "$here/batch-lib.sh"
. "$here/deploy-lib.sh"
mode=full; base=main
if [ "$1" = --ships ]; then
  cfg=$(cat .claude/deploy.json 2>/dev/null || true)
  app=$(json_string "$cfg" appRoot); app=${app:-.}
  deploy_skip "$(git diff --name-only "$2" "$3" 2>/dev/null)" "$app" "$(json_words "$cfg" neverShips)" | sed 's/^build$/build/'
  exit 0
fi
for a in "$@"; do case "$a" in --last) mode=last ;; *) base=$a ;; esac; done
[ -f .claude/deploy.json ] || { echo "deploy: no .claude/deploy.json, nothing gates it"; exit 0; }
interval=$(json_number "$(cat .claude/deploy.json)" intervalMinutes); [ -n "$interval" ] || interval=60
last_at=$(gh api "repos/{owner}/{repo}/actions/workflows/deploy.yml/runs?status=success&branch=$base&per_page=1" --jq '.workflow_runs[0].updated_at // ""' 2>/dev/null | tr -d '\r' || true)
last=""
if [ -n "$last_at" ]; then
  last=$(date -u -d "$last_at" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$last_at" +%s 2>/dev/null || true)
fi
green=0
if [ "$mode" = full ]; then
  for sha in $(gh api "repos/{owner}/{repo}/pulls?state=open&base=$base&per_page=100" --jq '.[] | select(.draft == false) | .head.sha' 2>/dev/null); do
    st=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" --jq '[.check_runs[] | .conclusion] | if length == 0 then "none" elif all(. == "success" or . == "skipped" or . == "neutral") then "green" else "other" end' 2>/dev/null | tr -d '\r')
    if [ "$st" = green ]; then green=$((green + 1)); fi
  done
fi
now=$(date +%s)
deploy_state "$green" "$last" "$now" "$interval"
if [ -n "$(deploy_gate "$green" "$last" "$now" "$interval")" ]; then exit 1; fi
exit 0
