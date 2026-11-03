#!/bin/sh
# The drain's rescue of builds placed on a machine that went offline.
# Sourced by scripts/ci/merge-queue.sh, which calls drain_rescue every
# round, and by scripts/ci/place-rescue.sh, which runs it once on a place
# that is up; functions only. The rules are rescue_on, rescue_runs and
# rescue_skip (queue/rules-rescue.sh); this reads the facts and acts on the
# answer. With "My machines only", or no order saved, it reads one variable
# per drain and does nothing else.

# rescue_var NAME: a repository variable's value, from the environment when
# the workflow passed it, else read once over REST; nothing when unset.
rescue_var() {
  eval "rv_v=\${$1:-}"
  if [ -z "$rv_v" ]; then rv_v=$(gh_write api "repos/{owner}/{repo}/actions/variables/$1" --jq .value 2>/dev/null | tr -d '\r' || true); fi
  printf '%s' "$rv_v"
}

# rescue_finish: start again each run this drain cancelled, once its cancel
# has ended; a run still ending is tried again at the next call.
rescue_finish() {
  rf_left=""
  for rf_run in $rescue_pending; do
    rf_status=$(gh api "repos/{owner}/{repo}/actions/runs/$rf_run" --jq .status 2>/dev/null | tr -d '\r' || true)
    if [ "$rf_status" = completed ]; then
      if gh_write api -X POST "repos/{owner}/{repo}/actions/runs/$rf_run/rerun" >/dev/null 2>&1; then
        say "round ${round:-1}: started build run $rf_run again, so it finds a place that is up."
      else
        say "round ${round:-1}: build run $rf_run was cancelled to move it, and could not be started again; use Run it again on it."
      fi
    else
      rf_left="$rf_left $rf_run"
    fi
  done
  rescue_pending=$rf_left
}

# drain_rescue: with an order of more than one place, cancel each run whose
# job waited past the wait limit with nowhere to run (rescue_runs), and
# start it again once the cancel has ended, so its place job chooses afresh.
drain_rescue() {
  if [ "${rescue_read:-}" != yes ]; then
    rescue_order=$(rescue_var SIPNSHIP_PLACES)
    rescue_refused=$(rescue_var SIPNSHIP_PLACE_REFUSED)
    rescue_pending=""; rescue_read=yes
  fi
  [ "$(rescue_on "$rescue_order")" = yes ] || return 0
  rescue_finish
  dr_now=$(date -u +%s)
  dr_runs=$({ gh api "repos/{owner}/{repo}/actions/runs?status=in_progress&per_page=20" --jq '.workflow_runs[] | [.id, .run_attempt] | @tsv'
    gh api "repos/{owner}/{repo}/actions/runs?status=queued&per_page=20" --jq '.workflow_runs[] | [.id, .run_attempt] | @tsv'; } 2>/dev/null | tr -d '\r' | sort -u)
  [ -n "$dr_runs" ] || return 0
  dr_jobs=$(printf '%s\n' "$dr_runs" | while IFS="$(printf '\t')" read -r dr_id dr_att; do
    [ -n "$dr_id" ] || continue
    gh api "repos/{owner}/{repo}/actions/runs/$dr_id/jobs?per_page=100" --jq ".jobs[] | [\"$dr_id\", \"$dr_att\", .name, .status, (.labels | join(\",\")), (.created_at | fromdateiso8601)] | @tsv" 2>/dev/null
  done | tr -d '\r')
  # The runners need a token that can read them; without one, nobody can
  # tell an offline machine from a busy one, so nothing is moved.
  if ! dr_runners=$(GH_TOKEN="${ADMIN_TOKEN:-${QUEUE_MERGE_TOKEN:-${GH_TOKEN:-}}}" gh api 'repos/{owner}/{repo}/actions/runners?per_page=100' --jq '.runners[] | [.status, (.busy | tostring), ([.labels[].name] | join(","))] | @tsv' 2>/dev/null); then
    [ "${rescue_said:-}" = yes ] || say "round ${round:-1}: the runners could not be read, so no stuck build is moved (the queue's App, or ADMIN_TOKEN, can read them)."
    rescue_said=yes; return 0
  fi
  dr_moved=no
  dr_old_ifs=$IFS; IFS='
'
  for dr_line in $(rescue_runs "$rescue_order" "$dr_jobs" "$dr_runners" "$dr_now"); do
    IFS=$dr_old_ifs
    set -- $dr_line
    if gh_write api -X POST "repos/{owner}/{repo}/actions/runs/$2/cancel" >/dev/null 2>&1; then
      say "round ${round:-1}: $(rescue_words "$3" "$4") (build run $2)"
      rescue_pending="$rescue_pending $2"; dr_moved=yes
      if [ "$4" = stuck ]; then
        rescue_refused=$(rescue_skip "$rescue_refused" "$3" "$dr_now")
        set_repo_var SIPNSHIP_PLACE_REFUSED "$rescue_refused" || say "round ${round:-1}: could not note that $(place_name "$3") is passed over for an hour; the next build may wait on it again."
      fi
    fi
  done
  IFS=$dr_old_ifs
  if [ "$dr_moved" = yes ]; then sleep 5; rescue_finish; fi
}
