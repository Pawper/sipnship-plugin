#!/bin/sh
# When the drain waits, and when it ends instead. Sourced by
# scripts/ci/merge-queue.sh; functions only.
#
# A drain on one of the project's CI runners that only waits holds a runner
# the checks it waits for need: one project's runners were all busy while a
# drain sat on one of them in two-minute steps, with a second drain queued
# behind it, and the green pull requests waited on checks that waited on a
# runner. So a drain on a runner ends when it has nothing to do now, says
# what it waits on, and is started again when a pull request's checks finish
# (queue-drain.yml's workflow_run trigger) or a person asks (queue-wake.yml).
# A drain run by hand in a terminal holds no runner and waits as before.

# drain_wait_where: "end" when this drain runs on a CI runner (GitHub
# Actions sets GITHUB_ACTIONS), "wait" in a terminal. QUEUE_DRAIN_WAIT=end
# or wait chooses either way.
drain_wait_where() {
  case "${QUEUE_DRAIN_WAIT:-}" in end|wait) echo "$QUEUE_DRAIN_WAIT"; return 0 ;; esac
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo end; else echo wait; fi
}

# drain_wait_step WHERE GREEN WAITING HELD LIMIT LOOKED (needs batch-lib.sh)
# What a drain round does once it has read the open pull requests. WHERE is
# drain_wait_where; GREEN how many it may merge now; WAITING how many are
# still running CI; HELD how many seconds the wait has lasted (the drain's
# own time, or on a runner how long the one green pull request has been
# green); LIMIT the bound in seconds (QUEUE_DRAIN_MINUTES); LOOKED is set
# after the one more look. Print one word:
#   merge     merge what is green now
#   hold      one green, others running: wait two minutes, then look again
#   end-hold  the same, on a runner: end; a drain starts when one finishes
#   wait      nothing green, others running: wait two minutes
#   end-wait  the same, on a runner: end; a drain starts when one finishes
#   stop      nothing green and others still running after LIMIT: stop
#   look      nothing green, nothing running: one more look in a minute
#   done      nothing left to merge
# On a runner there is no one more look: a pull request that turns green
# just after this read starts a drain of its own, which runs after this one.
drain_wait_step() {
  # The hold itself is drain_hold's rule (queue/rules-drain.sh).
  if [ "$(drain_hold "${2:-0}" "${3:-0}")" = yes ] && [ "${4:-0}" -lt "${5:-0}" ]; then
    [ "$1" = end ] && echo end-hold || echo hold
    return 0
  fi
  if [ "${2:-0}" -gt 0 ]; then echo merge; return 0; fi
  if [ "${3:-0}" -gt 0 ]; then
    if [ "${4:-0}" -ge "${5:-0}" ]; then echo stop
    elif [ "$1" = end ]; then echo end-wait
    else echo wait; fi
    return 0
  fi
  if [ "$1" = end ] || [ -n "${6:-}" ]; then echo done; else echo look; fi
}

# drain_held_for ELAPSED SINCE NOW: how long a hold has lasted, in seconds:
# the drain's own time, or since SINCE (the epoch the green pull request's
# required check passed), whichever is longer. A drain that ends at each
# hold never runs long itself, so on a runner the bound counts from the
# green check, and a green pull request is held no longer than before.
drain_held_for() {
  dhf=${1:-0}
  if [ -n "${2:-}" ] && [ "${2:-0}" -gt 0 ] 2>/dev/null; then
    dhf_age=$(( ${3:-0} - $2 ))
    [ "$dhf_age" -le "$dhf" ] || dhf=$dhf_age
  fi
  echo "$dhf"
}

# drain_end_line KIND WAITING [QUEUED_ONLY]: the drain's last line when it
# ends rather than wait. KIND is hold or wait.
drain_end_line() {
  del_q=""; [ "${3:-}" = yes ] && del_q=", whose checks are all queued for a runner"
  case "$1" in
    hold) printf 'One pull request is green and %s still running CI%s; it is held so a merge alone does not send them back round CI. Ending here to free this runner; a drain starts again when one of their checks finishes.\n' "$2" "$del_q" ;;
    *) printf 'Nothing is green yet; waiting on %s pull request(s) still running CI%s. Ending here to free this runner; a drain starts again when one of their checks finishes.\n' "$2" "$del_q" ;;
  esac
}

# green_since PR: the epoch the required check passed on the pull request's
# head (from the round's listing), or nothing. One REST call.
green_since() {
  gs_sha=$(printf '%s\n' "$listed" | awk -F'\t' -v n="$1" '$1 == n { print $3; exit }')
  [ -n "$gs_sha" ] || return 0
  gs_at=$(gh api "repos/{owner}/{repo}/commits/$gs_sha/check-runs?per_page=100" --jq ".check_runs[] | select(.name == \"${QUEUE_SUMMARY_CHECK:-CI passed}\") | .completed_at // empty" 2>/dev/null | tr -d '\r' | head -n 1)
  [ -z "$gs_at" ] || iso_epoch "$gs_at"
}

# drain_stall: waiting on CI or on a machine? When every pending pull
# request's checks are queued and no runner is online, waiting is pointless:
# say so and return 1, so the drain stops. Sets queued_only for the round.
drain_stall() {
  queued_only=no
  [ "$waiting" -gt 0 ] || return 0
  ds_statuses=$(printf '%s\n' "$open" | awk -F'\t' -v b="$base" '$2 == "false" && $5 == b && $4 == "pending" { print $1 }' | while read -r w_num; do
    w_sha=$(printf '%s\n' "$listed" | awk -F'\t' -v n="$w_num" '$1 == n { print $3; exit }')
    if [ -n "$w_sha" ]; then gh api "repos/{owner}/{repo}/commits/$w_sha/check-runs?per_page=100" --jq '.check_runs[].status' 2>/dev/null; fi
  done)
  queued_only=$(checks_queued_only "$ds_statuses")
  ds_stall=$(runner_stall "$queued_only" "$(online_runners)")
  printf 'round %s of %s; %s pull request(s) waiting%s\n' "$round" "$rounds" "$waiting" "$( [ "$queued_only" = yes ] && echo ' on queued checks, which no runner has taken')" > "$flaky_dir/drain.state"
  if [ "$ds_stall" = stop ]; then
    say "round $round: $waiting pull request(s) wait on checks that are all queued, and no self-hosted runner is online. Start a runner (scripts/ci/RUNNERS.md), then run --drain again; waiting would change nothing."
    return 1
  elif [ "$ds_stall" = unknown ] && [ -z "${said_unknown:-}" ]; then
    say "round $round: the checks are all queued, and the runners could not be read (set ADMIN_TOKEN to let the queue see them); if none is online, start one."
    said_unknown=1
  fi
  return 0
}
