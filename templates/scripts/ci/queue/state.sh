#!/bin/sh
# The merge queue's state: the writes to GitHub, the API budget, the facts
# about a pull request, the log line, the lock and the exit trap. Sourced by
# scripts/ci/merge-queue.sh; functions only, run from its variables.

# gh_write ARGS: every gh call that changes GitHub goes through here, with
# QUEUE_MERGE_TOKEN when it is set (a token whose changes start follow-on
# workflows), else GH_TOKEN. Reads keep GH_TOKEN.
gh_write() { GH_TOKEN="${QUEUE_MERGE_TOKEN:-${GH_TOKEN:-}}" gh "$@"; }

# set_repo_var NAME VALUE: a repository variable, which the scheduled
# drain workflow reads as vars.NAME. Needs a token that can administer the
# repository (the owner's own gh sign-in can).
set_repo_var() {
  gh_write api -X PATCH "repos/{owner}/{repo}/actions/variables/$1" -f name="$1" -f value="$2" >/dev/null 2>&1 \
    || gh_write api -X POST "repos/{owner}/{repo}/actions/variables" -f name="$1" -f value="$2" >/dev/null 2>&1
}
iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

say() { echo "$1"; printf '%s %s\n' "$(date '+%H:%M')" "$1" >> "$log_file" 2>/dev/null || true; }
hhmm() { date -u -d "@$1" +%H:%M 2>/dev/null || date -u -r "$1" +%H:%M 2>/dev/null || echo "$1"; }

# The REST budget only: every call the queue makes is REST, so a spent
# GraphQL budget (gh pr, gh issue, the board) never holds it. It once waited
# for the GraphQL reset with REST half full.
rate_budget() { gh api rate_limit --jq '.resources.core | "\(.remaining)\t\(.reset)"' 2>/dev/null || true; }
rate_guard() {
  rg=$(rate_budget)
  w=$(rate_wait "$rg" "$(date +%s)" "${QUEUE_RATE_FLOOR:-500}")
  [ "$w" -gt 0 ] || return 0
  echo "GitHub API budget is low (${rg%%	*} calls left); waiting $((w / 60 + 1)) minute(s) until it resets at $(hhmm "${rg#*	}") UTC."
  sleep "$w"
}
# rate_stop: after a gh call whose stderr went to $gh_err, back off when
# GitHub refused it for a rate limit. The hourly quota spent: wait for the
# reset. The secondary limit, which the budget read cannot see: 60 seconds,
# then 120, 240 and 480, and the fifth refusal stops; never retry at once. rate_ok clears the
# count after a round that went through.
rate_stop() {
  [ "$(rate_limit_hit "$(cat "$gh_err" 2>/dev/null)")" = yes ] || return 0
  : > "$gh_err"
  rg=$(rate_budget); rem=${rg%%	*}
  if [ "${rem:-1}" = 0 ]; then
    w=$(rate_wait "$rg" "$(date +%s)" 1)
    echo "GitHub's hourly API quota is spent; waiting until it resets at $(hhmm "${rg#*	}") UTC."
    sleep "$w"; return 0
  fi
  n=$(cat "$flaky_dir/rate.hits" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$flaky_dir/rate.hits"
  case $n in
    1) w=60 ;;
    2) w=120 ;;
    3) w=240 ;;
    4) w=480 ;;
    *) say "GitHub refused five calls for its secondary rate limit (too many concurrent or point-heavy requests from this account); stopping. Run the queue again in ten minutes, one copy, with nothing else polling."; exit 1 ;;
  esac
  say "GitHub refused the call for its secondary rate limit, which the budget read cannot see (hit $n of 5); waiting $w seconds, never retrying at once."
  sleep "$w"
}
rate_ok() { rm -f "$flaky_dir/rate.hits" 2>/dev/null || true; }

# Pull request facts through REST, one call per pull request, cached for
# sixty seconds. pr_field N COL: 1 head ref, 2 head sha, 3 title, 4 draft,
# 5 mergeable_state, 6 base ref, 7 state. pr_rollup SHA: the check-runs of
# a commit as one word, none, red, pending or green.
pr_tsv() {
  pt_f="$flaky_dir/pr-$1.tsv"
  pt_age=$(( $(date +%s) - $(stat -c %Y "$pt_f" 2>/dev/null || stat -f %m "$pt_f" 2>/dev/null || echo 0) ))
  if [ ! -s "$pt_f" ] || [ "$pt_age" -gt 60 ]; then
    if gh api "repos/{owner}/{repo}/pulls/$1" --jq '[.head.ref, .head.sha, .title, (.draft | tostring), (.mergeable_state // ""), .base.ref, .state] | @tsv' > "$pt_f.tmp" 2>"$gh_err"; then
      mv "$pt_f.tmp" "$pt_f"
    else
      rm -f "$pt_f.tmp" 2>/dev/null; rate_stop
    fi
  fi
  cat "$pt_f" 2>/dev/null || true
}
pr_field() { pr_tsv "$1" | cut -f"$2" | tr -d '\r'; }
# job_real_outcome JOB_ID CONCLUSION: a cancelled job whose own step failed
# is a failure (job_outcome); one REST call, only for a cancelled job.
job_real_outcome() {
  case "$2" in
    cancelled|canceled) job_outcome "$2" "$(gh api "repos/{owner}/{repo}/actions/jobs/$1" --jq '[.steps[]?.conclusion // empty] | join(" ")' 2>/dev/null)" ;;
    *) echo "$2" ;;
  esac
}
# check_lines SHA: "name<TAB>outcome" per check run, with job_real_outcome.
check_lines() {
  gh api "repos/{owner}/{repo}/commits/$1/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)\t\(.id)"' 2>"$gh_err" \
  | tr -d '\r' | while IFS="$(printf '\t')" read -r cl_name cl_out cl_id; do
    printf '%s\t%s\n' "$cl_name" "$(job_real_outcome "$cl_id" "$cl_out")"
  done
}
pr_rollup() {
  rest_rollup_named "$(check_lines "$1" || { rate_stop; echo; })" "${QUEUE_SUMMARY_CHECK:-CI passed}"
}

unlock() { if [ "$have_lock" = yes ]; then rm -f "$lock_file" 2>/dev/null; remote_lock_release; fi; have_lock=no; }
# queue_exit: the one exit trap. The queue never stops without a word:
# under set -e a failing command ends it at once, and twice that was a
# drain exiting 1 with nothing printed, overnight, so nothing merged. A
# drain run in a session also clears its "draining" mark here.

# fetch_base [REFSPEC...]: fetch main (and REFSPEC), retrying when it
# fails. Another fetch in the same repository moving origin/main at that
# moment fails ours with "cannot lock ref ... is at X but expected Y"; one
# lost race once ended a batch of four green pull requests, and the drain
# called the round "nothing green". Three tries, a few seconds apart; the
# last failure is said and returned, never read as nothing to merge.
fetch_base() {
  fb_try=1
  while :; do
    if git fetch -q origin "$base" "$@" 2>"$flaky_dir/fetch.err"; then return 0; fi
    if [ "$fb_try" -ge 3 ]; then
      echo "Could not fetch $base: $(head -n 1 "$flaky_dir/fetch.err" 2>/dev/null | tr -d '\r')" >&2
      return 1
    fi
    fb_try=$((fb_try + 1))
    sleep 3
  done
}

# publish_now MODE: write the queue's state to the Merge queue issue
# (scripts/ci/publish-state.sh, spec 001), when the project has switched
# it on. Bounded, never fatal: publishing never stops a merge.
# publish_cap: "timeout N" when QUEUE_PUBLISH_SECONDS is set, so the exit
# trap's last picture never holds the run (it once read a dozen pull
# requests call by call after the drain's own work was done).
publish_cap() { [ -z "${QUEUE_PUBLISH_SECONDS:-}" ] || ! command -v timeout >/dev/null 2>&1 || printf 'timeout %s' "$QUEUE_PUBLISH_SECONDS"; }
publish_now() {
  [ -f "$here/publish-state.sh" ] || return 0
  QUEUE_BASE="$base" QUEUE_DIR="$flaky_dir" $(publish_cap) sh "$here/publish-state.sh" --mode "$1" ${2:+--open "$2"} 2>>"$flaky_dir/publish.err" | while IFS= read -r pn_l; do say "$pn_l"; done
  return 0
}

# remote_drain_stuck RUNS NOW: a Queue drain that has sat queued on GitHub
# past QUEUE_STUCK_SECONDS (default ten minutes) never started a job; it is
# named here and no longer blocks a local landing (remote_drain_reason).
remote_drain_stuck() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v stuck="${QUEUE_STUCK_SECONDS:-600}" '
    NR == 1 && NF >= 3 && $1 != "" && $2 == "queued" && now - ($3 + 0) > stuck {
      printf "the Queue drain on GitHub (run %s) has sat queued for %d minute(s) and started no job\n", $1, int((now - ($3 + 0)) / 60)
      exit
    }'
}

# drain_retry_once: a drain that ended in failure while requests were open
# starts one more drain within minutes, once. "Once" is a repository variable
# read by every machine, so a retry that fails on another runner is not
# retried again for QUEUE_RETRY_GAP seconds (default 1800).
drain_retry_once() {
  [ -f "$flaky_dir/requests.open" ] || return 0
  [ -f .github/workflows/queue-drain.yml ] || return 0
  dr_now=$(date +%s)
  dr_last=$(gh api "repos/{owner}/{repo}/actions/variables/QUEUE_DRAIN_RETRIED" --jq .value 2>/dev/null | tr -d '\r')
  [ $(( dr_now - ${dr_last:-0} )) -ge "${QUEUE_RETRY_GAP:-1800}" ] 2>/dev/null || return 0
  set_repo_var QUEUE_DRAIN_RETRIED "$dr_now" || true
  if gh_write api -X POST "repos/{owner}/{repo}/actions/workflows/queue-drain.yml/dispatches" -f ref="$base" >/dev/null 2>&1; then
    say "The drain stopped while requests were open; one more drain is started, once."
  fi
  return 0
}

queue_exit() {
  qe_rc=$?
  # A batch ends with the run: nothing stale is drawn after it.
  : > "$flaky_dir/batch.state" 2>/dev/null || true
  # The last word on the issue: idle, with what landed.
  case "${mode:-}" in drain|serial|batch) QUEUE_PUBLISH_SECONDS=${QUEUE_EXIT_PUBLISH_SECONDS:-60} publish_now idle ;; esac
  # The console's "what the queue is doing now" line ends with the run.
  : > "$flaky_dir/now" 2>/dev/null || true
  if [ "$qe_rc" -ne 0 ]; then
    echo "merge-queue.sh stopped (exit $qe_rc) during: $queue_step" >&2
    printf '%s %s\n' "$(date '+%H:%M')" "stopped (exit $qe_rc) during: $queue_step" >> "$log_file" 2>/dev/null || true
  fi
  if [ "${mode:-}" = drain ] && { [ "$qe_rc" -ne 0 ] || [ -f "$flaky_dir/requests.failed" ]; }; then drain_retry_once || true; fi
  if [ -n "${local_drain_mark:-}" ]; then set_repo_var QUEUE_LOCAL_DRAIN_UNTIL "" >/dev/null 2>&1 || true; fi
  # The run's last word, in the log as well as the terminal, after the
  # deploy and after the lock goes: four watchers once waited on a "queue
  # done" that only the terminal saw.
  if [ "$have_lock" = yes ]; then
    unlock
    [ "$qe_rc" -ne 0 ] || echo "queue done"
    printf '%s %s\n' "$(date '+%H:%M')" "queue done (exit $qe_rc); lock released" >> "$log_file" 2>/dev/null || true
  fi
}
take_lock() {
  [ -z "$QUEUE_LOCKED" ] || return 0
  l=$(cat "$lock_file" 2>/dev/null || true)
  lpid=${l%%	*}
  alive=no; [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && alive=yes
  why=$(queue_lock_reason "$l" "$(date +%s)" "$alive")
  if [ -z "$why" ] && [ -z "${GITHUB_ACTIONS:-}" ]; then
    # The Queue drain workflow on GitHub is a queue too: one REST call, and a
    # failed call (no network, rate limit) never blocks.
    if rr=$(gh api "repos/{owner}/{repo}/actions/workflows/queue-drain.yml/runs?per_page=5" --jq '.workflow_runs[] | select(.status == "in_progress" or .status == "queued") | [.id, .status, .created_at] | @tsv' 2>/dev/null); then
      IFS="	" read -r r_id r_st r_at <<EOF_RUN
$(printf '%s\n' "$rr" | head -n 1)
EOF_RUN
      rruns=""
      if [ -n "$r_id" ]; then rruns=$(printf '%s\t%s\t%s' "$r_id" "$r_st" "$(iso_epoch "$r_at")"); fi
      why=$(remote_drain_reason "$rruns" "$(date +%s)"); [ -z "$why" ] || remote_id=$r_id
      [ -n "$why" ] || { stuck=$(remote_drain_stuck "$rruns" "$(date +%s)"); [ -z "$stuck" ] || say "$stuck; going on without it."; }
    else
      echo "Could not check whether the Queue drain is running on GitHub; going on."
    fi
  fi
  if [ -n "$why" ]; then
    # A run on GitHub is quoted by its own current step; this machine's log is another run's.
    last=""; if [ -n "${remote_id:-}" ]; then last=$(gh api "repos/{owner}/{repo}/actions/runs/$remote_id/jobs" --jq '[.jobs[].steps[]? | select(.status == "in_progress") | .name][0] // empty' 2>/dev/null | tr -d '\r'); [ -z "$last" ] || last="step \"$last\""; else last=$(tail -n 1 "$flaky_dir/log" 2>/dev/null | cut -c1-160); fi
    st=""; [ -n "${remote_id:-}" ] || st=$(cat "$flaky_dir/drain.state" 2>/dev/null | head -n 1)
    [ -n "$st" ] && last="$st; ${last}"
    follow="tail -f .scratch/queue/log"; [ -z "${remote_id:-}" ] || follow="gh api repos/{owner}/{repo}/actions/runs/$remote_id/jobs, its own log on GitHub"
    echo "Another queue is running: $why${last:+; its last line: $last}. Wait for it to finish rather than starting a second one; follow it with $follow."
    exit 1
  fi
  # The lock every queue sees, on GitHub (queue/lock.sh), before this checkout's own.
  remote_lock_take
  printf '%s\t%s\t%s\n' "$$" "$(date +%s)" "--$mode" > "$lock_file"
  have_lock=yes
  printf '%s %s\n' "$(date '+%H:%M')" "lock taken by --$mode (pid $$)" >> "$log_file" 2>/dev/null || true
  QUEUE_LOCKED=1; export QUEUE_LOCKED
  trap queue_exit EXIT
}

iso_epoch() { # ISO 8601 -> epoch seconds, GNU or BSD date
  [ -n "$1" ] || { echo 0; return; }
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0
}

# With no queue App and no QUEUE_TOKEN the drain works with the workflow's
# own token (QUEUE_OWN_TOKEN=yes). A push, a pull request or a merge by that
# token starts no run by itself, but a dispatched run does (GitHub's
# documented exception), so the queue starts CI on the ref itself: the batch's
# branch once its pull request is open, and the base after a landing. The run
# is reported on that commit like any other, so the batch's required check
# counts it (scripts/ci/QUEUE.md, "With no queue App").
ci_dispatch() {
  [ "${QUEUE_OWN_TOKEN:-}" = yes ] && [ -z "${QUEUE_MERGE_TOKEN:-}" ] || return 0
  if gh_write api -X POST "repos/{owner}/{repo}/actions/workflows/ci.yml/dispatches" -f ref="$1" >/dev/null 2>&1; then
    say "Started CI on $1 with the workflow's own token."
  else
    say "Could not start CI on $1; start it from the Actions page."
  fi
}

# The workflow's own token may not change workflow files. Said plainly when a
# refused merge names them: that change waits for a drain run on a machine.
workflow_wait_note() {
  [ "${QUEUE_OWN_TOKEN:-}" = yes ] || return 0
  grep -qi 'workflow' "$1" 2>/dev/null || return 0
  printf ' This change touches workflows, which the workflow'"'"'s own token cannot land; it waits for a drain run on your machine (sh scripts/ci/merge-queue.sh --drain).'
}

