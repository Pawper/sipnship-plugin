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
# Only a pull request the drain would land holds the deploy: not a draft,
# and not held (a queue:hold label or a "Queue: hold" line, the drain's own
# held_reason). A held one never lands in a drain, so waiting for it once
# kept a merged fix from deploying at all; it is counted apart and said.
# An empty labels column is written "-": a tab is IFS whitespace, so two in a
# row would collapse and put the body in the labels column.
green=0; held_green=0
if [ "$mode" = full ]; then
  tab=$(printf '\t')
  gh api "repos/{owner}/{repo}/pulls?state=open&base=$base&per_page=100" --jq '.[] | select(.draft == false) | "\(.number)\t\(.head.sha)\t\(([.labels[].name] | join(",") | if . == "" then "-" else . end))\t\((.body // "") | gsub("[\r\n]+"; " | "))"' 2>/dev/null > "${TMPDIR:-/tmp}/deploy-gate.$$" || true
  while IFS="$tab" read -r g_num sha g_labels g_body; do
    [ -n "$sha" ] || continue
    [ "$g_labels" = - ] && g_labels=""
    # Only one the queue can still merge now; QUEUE_DEPLOY_SKIP names the
    # ones this drain tried and left open.
    [ "$(deploy_waits_for "$g_num" "$g_labels" "${QUEUE_DEPLOY_SKIP:-}")" = yes ] || continue
    st=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" --jq '[.check_runs[] | .conclusion] | if length == 0 then "none" elif all(. == "success" or . == "skipped" or . == "neutral") then "green" else "other" end' 2>/dev/null | tr -d '\r')
    [ "$st" = green ] || continue
    g_why=$(held_reason "$(printf '%s' "$g_labels" | tr ',' '\n')" "$(printf '%s' "$g_body" | sed 's/ | /\
/g')")
    if [ -n "$g_why" ]; then held_green=$((held_green + 1)); else green=$((green + 1)); fi
  done < "${TMPDIR:-/tmp}/deploy-gate.$$"
  rm -f "${TMPDIR:-/tmp}/deploy-gate.$$"
  # Main's full gate (gate.sh): a head goes on its own green landing run;
  # only a red gate on main newer than the head's landing holds it.
  if [ -f "$here/gate-lib.sh" ]; then
  . "$here/gate-lib.sh"
  g_landed=$(gh api "repos/{owner}/{repo}/commits/$base" --jq '.commit.committer.date' 2>/dev/null | tr -d '\r' || true)
  g_landed=$(date -u -d "$g_landed" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$g_landed" +%s 2>/dev/null || true)
  g_why=$(gate_holds_deploy "$(sh "$here/gate.sh" last 2>/dev/null)" "$g_landed")
  if [ -n "$g_why" ]; then echo "deploy: held, $g_why"; exit 1; fi
  fi
fi
now=$(date +%s)
# The hold is bounded: QUEUE_DEPLOY_HELD_DRAINS (the drains in a row that
# held it, which the queue passes) or QUEUE_DEPLOY_MAX_HOLD minutes since the
# last deploy, and it goes anyway, saying why. The queue still starts
# nothing when nothing that ships landed.
if [ "$green" -gt 0 ]; then
  bound=$(deploy_hold_bound "${QUEUE_DEPLOY_HELD_DRAINS:-0}" "$last" "$now" "${QUEUE_DEPLOY_MAX_HOLD:-30}")
  if [ -n "$bound" ]; then
    echo "deploy: due anyway, $(deploy_gate "$green" "" "$now" "$interval") but $bound"
    held_note "$held_green"
    exit 0
  fi
fi
deploy_state "$green" "$last" "$now" "$interval"
held_note "$held_green"
if [ -n "$(deploy_gate "$green" "$last" "$now" "$interval")" ]; then exit 1; fi
exit 0
