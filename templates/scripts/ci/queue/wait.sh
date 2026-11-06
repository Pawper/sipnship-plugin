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

# drain_end_line KIND WAITING [QUEUED_ONLY] [BOUND]: the drain's last line when
# it ends rather than wait. KIND is hold or wait; BOUND is hold_bound_said's.
drain_end_line() {
  del_q=""; [ "${3:-}" = yes ] && del_q=", whose checks are all queued for a runner"
  del_b=""; [ -n "${4:-}" ] && del_b=" It is held $4; once that time has passed, the next drain that runs lands it alone."
  case "$1" in
    hold) printf 'One pull request is green and %s still running CI%s; it is held so a merge alone does not send them back round CI.%s Ending here to free this runner; a drain starts again when one of their checks finishes.\n' "$2" "$del_q" "$del_b" ;;
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

# --- What the hold says, to a person and in the published state (spec 001,
# "holds"). The rule is unchanged: drain_hold decides a hold, drain_held_for
# how long it has lasted, drain_wait_step when it ends. These only say it.
# Nothing starts a drain at the moment the bound passes: a drain starts when
# a pull request's checks finish, every two hours, and on request. So the
# bound is the latest the queue holds the change; from then on the next drain
# that runs lands it alone, and the words never promise an exact minute.

# hold_iso EPOCH: UTC as 2026-11-06T16:40:00Z.
hold_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# hold_clock EPOCH: UTC as 16:40 (a runner's log is read in UTC).
hold_clock() { date -u -d "@$1" +%H:%M 2>/dev/null || date -u -r "$1" +%H:%M 2>/dev/null; }

# drain_held_now WHERE GREEN WAITING ELAPSED PICK: seconds the hold has lasted
# (drain_held_for): on a runner counted from when the one green change turned
# green, in a terminal the drain's own time.
drain_held_now() {
  dhn_for=${4:-0}
  if [ "${1:-}" = end ] && [ "$(drain_hold "${2:-0}" "${3:-0}")" = yes ]; then
    dhn_for=$(drain_held_for "$dhn_for" "$(green_since "$5")" "$(date +%s)")
  fi
  echo "$dhn_for"
}

# hold_bound_said WHERE HELD_FOR LIMIT NOW: "no later than 16:40 UTC (25
# minutes after it turned green)", the time the hold ends at the latest.
hold_bound_said() {
  hbs_end=$(( ${4:-0} - ${2:-0} + ${3:-0} ))
  hbs_from="after it turned green"; [ "${1:-}" = end ] || hbs_from="after this drain began"
  printf 'no later than %s UTC (%s %s)' "$(hold_clock "$hbs_end")" "$(( ${3:-0} / 60 )) minutes" "$hbs_from"
}

# drain_hold_note STEP PICK HELD_FOR LIMIT: the hold the round just decided, one
# line "number<TAB>held since (epoch)<TAB>limit (seconds)" in the queue's folder
# for publish-state.sh, or emptied when this round does not hold.
drain_hold_note() {
  case "$1" in
    hold|end-hold) printf '%s\t%s\t%s\n' "$(printf '%s' "$2" | tr -d ' \n')" "$(( $(date +%s) - ${3:-0} ))" "${4:-0}" > "$flaky_dir/hold.tsv" 2>/dev/null || true ;;
    *) : > "$flaky_dir/hold.tsv" 2>/dev/null || true ;;
  esac
}

# hold_open_say OPEN HOLD: OPEN (number, title, state, say per line) with the
# held change's sentence saying it is held; its state stays green. HOLD is
# hold.tsv's line. Unchanged when no one is waiting, so a stale line says nothing.
hold_open_say() {
  printf '%s\n' "$1" | awk -F'\t' -v OFS='\t' -v h="$(printf '%s' "$2" | cut -f1)" '
    { n++; row[n] = $0; if ($3 == "waiting") w++ }
    END {
      for (i = 1; i <= n; i++) {
        split(row[i], f, "\t")
        if (h != "" && w > 0 && f[1] == h && f[3] == "green") print f[1], f[2], f[3], "green, held for a batch so a merge alone does not send " (w == 1 ? "the change" : "the " w " changes") " still running CI back round CI"
        else print row[i]
      }
    }' | sed '/^$/d'
}

# hold_json OPEN HOLD: the published "holds" array: the held green change, when
# the hold counted from, when it ends at the latest, the limit in minutes, and
# the changes it waits for. "[]" when the line is empty, the change is not
# green or nothing is still running CI.
hold_json() {
  hj_n=$(printf '%s' "$2" | cut -f1); hj_s=$(printf '%s' "$2" | cut -f2); hj_l=$(printf '%s' "$2" | cut -f3)
  case "$hj_n$hj_s$hj_l" in *[!0-9]*|'') printf '[]'; return 0 ;; esac
  [ "$hj_s" -gt 0 ] && [ "$hj_l" -gt 0 ] || { printf '[]'; return 0; }
  printf '%s\n' "$1" | awk -F'\t' -v n="$hj_n" '$1 == n && $3 == "green" { f = 1 } END { exit !f }' || { printf '[]'; return 0; }
  hj_w=$(printf '%s\n' "$1" | awk -F'\t' '$3 == "waiting" { printf "%s ", $1 }')
  [ -n "$hj_w" ] || { printf '[]'; return 0; }
  printf '[{"number":%s,"heldSince":%s,"endsAt":%s,"limitMinutes":%s,"waitingFor":%s}]' "$hj_n" "$(json_str "$(hold_iso "$hj_s")")" "$(json_str "$(hold_iso $((hj_s + hj_l)))")" "$((hj_l / 60))" "$(json_list "$hj_w")"
}

# hold_json_add JSON HOLDS: the state's JSON with its "holds" array added at
# the end, as service_body adds "waits"; version 1, nothing else changes.
hold_json_add() {
  printf '%s' "$1" | sed 's/}[[:space:]]*$//' | tr -d '\n'
  printf ',"holds":%s}\n' "${2:-[]}"
}
