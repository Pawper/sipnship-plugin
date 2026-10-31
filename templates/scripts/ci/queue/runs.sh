#!/bin/sh
# Reading a CI run and waiting for it: the run, its jobs, the required
# check, the runners, a diagnosis, the flaky record. Sourced by
# scripts/ci/merge-queue.sh; functions only.

# latest_run BRANCH -> "id<TAB>status<TAB>conclusion": the newest run of the
# CI workflow on the branch (QUEUE_CI_WORKFLOW, default ci.yml). The newest
# run of any workflow was once a quick side workflow that finished first
# and read as green, and GitHub refused the merge twice: "Required status
# check CI passed is expected".
latest_run() {
  gh run list --branch "$1" --workflow "${QUEUE_CI_WORKFLOW:-ci.yml}" --limit 1 --json databaseId,status,conclusion --jq '.[0] | "\(.databaseId)\t\(.status)\t\(.conclusion // "")"' 2>"$gh_err" || true
}

jobs_of() { # RUN_ID -> one job per line for run_verdict
  gh run view "$1" --json jobs --jq '.jobs[] | [.name, .status, (.conclusion // ""), (.startedAt // ""), .databaseId] | @tsv' 2>/dev/null \
  | while IFS="$tab" read -r name status conc started jobid; do
    conc=$(job_real_outcome "$jobid" "$conc")
    # Annotations: for a job still waiting (an outage) and for one that
    # failed with no step run (a billing refusal says so only there).
    ann=""
    if [ "$status" != "completed" ] || [ "$conc" = failure ] || [ "$conc" = startup_failure ]; then
      ann=$(gh api "repos/{owner}/{repo}/check-runs/$jobid/annotations" --jq '[.[].message] | join("; ")' 2>/dev/null | tr '\t\n' '  ')
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$conc" "$(iso_epoch "$started")" "$ann"
  done
}

# main_state: green, red or pending for main's newest CI run on main's
# current commit; pending when that commit has no completed run yet,
# unknown when it cannot be read. One REST call.
main_state() {
  ms_head=$(git rev-parse "origin/$base" 2>/dev/null)
  ms=$(gh api "repos/{owner}/{repo}/actions/workflows/${QUEUE_CI_WORKFLOW:-ci.yml}/runs?branch=$base&event=push&per_page=1" --jq '.workflow_runs[0] | "\(.head_sha)\t\(.status)\t\(.conclusion // "")"' 2>/dev/null) || { echo unknown; return 0; }
  [ -n "$ms" ] || { echo unknown; return 0; }
  ms_sha=${ms%%	*}; ms_rest=${ms#*	}; ms_status=${ms_rest%%	*}; ms_conc=${ms_rest#*	}
  if [ "$ms_sha" != "$ms_head" ] || [ "$ms_status" != completed ]; then echo pending
  elif [ "$ms_conc" = success ]; then echo green
  else echo red; fi
}

# required_on SHA: the required check's state on one commit.
required_on() {
  required_check "$(gh api "repos/{owner}/{repo}/commits/$1/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "")"' 2>/dev/null)" "${QUEUE_SUMMARY_CHECK:-CI passed}"
}

# wait_required SHA: poll the required check on SHA every thirty seconds
# until it passes (0) or fails (1), or the wait runs out (3). A green
# workflow run is not enough: the check must exist on this commit.
wait_required() {
  wr_start=$(date +%s)
  while :; do
    case "$(required_on "$1")" in
      passed) return 0 ;;
      failed) echo "The required check \"${QUEUE_SUMMARY_CHECK:-CI passed}\" failed on $1."; return 1 ;;
    esac
    if [ $(( $(date +%s) - wr_start )) -gt $((wait_minutes * 60)) ]; then
      echo "The required check \"${QUEUE_SUMMARY_CHECK:-CI passed}\" has not passed on $1 after $wait_minutes minutes; giving up for now."
      return 3
    fi
    sleep 30
  done
}

# online_runners: how many self-hosted runners are online, or "unknown".
# The owner's token can read them; ADMIN_TOKEN is used when set.
online_runners() {
  or_n=$(GH_TOKEN="${ADMIN_TOKEN:-${GH_TOKEN:-}}" gh api 'repos/{owner}/{repo}/actions/runners' --jq '[.runners[] | select(.status == "online")] | length' 2>/dev/null) || or_n=""
  [ -n "$or_n" ] && echo "$or_n" || echo unknown
}

idle_runners() { gh api 'repos/{owner}/{repo}/actions/runners' --jq '[.runners[] | select(.status == "online" and .busy == false)] | length' 2>/dev/null || echo 0; }

github_status() { # one line when GitHub says Actions is degraded, else nothing
  githubstatus_verdict "$(curl -s --max-time 5 https://www.githubstatus.com/api/v2/components.json 2>/dev/null)"
}

# diagnose RUN_ID -> prints one plain line about the run and returns:
# 0 green, 1 failed, 2 pending, 3 outage, 4 canceled
diagnose() {
  d_jobs=$(jobs_of "$1")
  d_verdict=$(run_verdict "$d_jobs" "$(date +%s)" "$(idle_runners)")
  case "$d_verdict" in
    green) return 0 ;;
    pending) return 2 ;;
    billing:*)
      billing_line "the job(s) ${d_verdict#billing: }" | tr -d '\n'; echo
      return 1 ;;
    outage:*)
      gs=$(github_status)
      echo "GitHub Actions is down, not your code: ${d_verdict#outage: }${gs:+ ($gs)}"
      return 3 ;;
    canceled:*)
      echo "The run you are waiting on was canceled (${d_verdict#canceled: }); re-running it."
      return 4 ;;
    failed:*)
      echo "CI failed: ${d_verdict#failed: }"
      return 1 ;;
  esac
}

# record_flaky PR RUN_ID RESULT: keep the per-test record. On a failure,
# the failing tests are read from the run's log; on a pass, the tests that
# failed earlier on this PR are marked passed, which is what a flake is.
record_flaky() {
  rf_log=""; [ -f "$flaky_dir/flaky.tsv" ] && rf_log=$(cat "$flaky_dir/flaky.tsv")
  rf_day=$(date +%Y-%m-%d)
  if [ "$3" = failed ]; then
    tests=$(failed_tests_from_log "$(gh run view "$2" --log-failed 2>/dev/null)")
    # A class job that failed with no test named (a lost log, a runner
    # hiccup) is recorded by its job name, so a job that fails and then
    # passes on re-run is the same flake signal as a test.
    [ -n "$tests" ] || tests=$(jobs_of "$2" | awk -F'\t' '$3 == "failure" { print "job:" $1 }')
    [ -n "$tests" ] && echo "Failing tests: $(printf '%s\n' "$tests" | head -n 5 | tr '\n' ';' | sed 's/;$//')"
  else
    tests=$(printf '%s\n' "$rf_log" | awk -F'\t' -v pr="$1" '$2 == pr && $4 == "failed" { print $3 }' | awk '!seen[$0]++')
  fi
  for t in $(printf '%s\n' "$tests" | tr ' ' '\001'); do
    t=$(printf '%s' "$t" | tr '\001' ' ')
    rf_log=$(flaky_log_add "$rf_log" "$rf_day" "$1" "$t" "$3")
  done
  printf '%s\n' "$rf_log" > "$flaky_dir/flaky.tsv"
  # A test that flaked twice gets an issue, once.
  flaky_offenders "$rf_log" 2 | while IFS="$tab" read -r count test prs; do
    [ -n "$test" ] || continue
    grep -qxF "$test" "$flaky_dir/flaky-filed.txt" 2>/dev/null && continue
    gh_write api -X POST "repos/{owner}/{repo}/issues" -f title="Flaky test: $test" -f 'labels[]=bug' -f "labels[]=$(state_label ready "$(project_label_form)")" \
      -f body="This test failed and then passed on retry $count times, on pull requests $prs. The merge queue recorded it. An unreliable test is a bug, not weather: fix it or quarantine it with its own issue, do not re-run it again." >/dev/null 2>&1 \
      && { printf '%s\n' "$test" >> "$flaky_dir/flaky-filed.txt"; echo "Filed an issue for the flaky test $test ($count flakes on $prs)."; }
  done
}

# wait_seen_end: a wait for a runner the queue saw has ended (or the queue
# stopped watching it); add it to .scratch/queue/waits.tsv. Local only.
wait_seen_end() {
  [ -n "${w_seen:-}" ] || return 0
  ws_now=$(date +%s)
  waits_append .scratch/queue/waits.tsv "$w_seen" "$w_job" "${w_busy:-0}" "${w_total:-0}" $(( (ws_now - w_seen + 59) / 60 )) || true
  w_seen=""
}

# wait_for_run PR BRANCH: wait for the branch's latest run, saying plainly
# what is happening. Returns 0 green, 1 red, 3 gave up.
wait_for_run() {
  w_start=$(date +%s); outage_on=no; w_seen=""
  while :; do
    rate_guard
    run=$(latest_run "$2"); run_id=${run%%	*}
    rate_stop
    [ -n "$run_id" ] || { echo "No run found for $2 yet."; sleep 30; continue; }
    # The batch's full run has started: publish which run it waits on, then
    # its progress every five minutes, or sooner when a moment was held back.
    if [ "$2" = "${branch:-}" ] && grep -q '^pr	' "$flaky_dir/batch.state" 2>/dev/null; then
      if ! grep -qx "run	$run_id" "$flaky_dir/batch.state" 2>/dev/null; then batch_note run "$run_id"; batch_moment testing
      elif [ -s "$flaky_dir/publish.pending" ] || [ $(( $(date +%s) - $(cat "$flaky_dir/published.at" 2>/dev/null || echo 0) )) -ge 300 ]; then publish_now batch; fi
    fi
    # set -e ends the script at a bare failing assignment, so the code is
    # caught here: a pending run (2) once exited the queue with no word.
    code=0; msg=$(diagnose "$run_id") || code=$?
    [ -n "$msg" ] && echo "$msg"
    case $code in 0|1) wait_seen_end ;; esac
    case $code in
      0) record_flaky "$1" "$run_id" passed
         if [ "$outage_on" = yes ] && [ -n "$QUEUE_OUTAGE_OFF" ]; then sh -c "$QUEUE_OUTAGE_OFF" && echo "Outage switch off again."; fi
         return 0 ;;
      1) record_flaky "$1" "$run_id" failed; return 1 ;;
      3) if [ "$outage_on" = no ] && [ -n "$QUEUE_OUTAGE_ON" ]; then sh -c "$QUEUE_OUTAGE_ON" && { outage_on=yes; echo "Outage switch on for this run."; }; fi ;;
      4) gh_write run rerun "$run_id" >/dev/null 2>&1 || true ;;
    esac
    if [ $(( $(date +%s) - w_start )) -gt $((wait_minutes * 60)) ]; then
      echo "Waited $wait_minutes minutes for run $run_id; giving up for now. Run the queue again later."
      wait_seen_end
      return 3
    fi
    # Waiting on machines or on tests? Every two minutes, say how many jobs
    # are queued and how busy the runners are.
    w_tick=$(( ${w_tick:-0} + 1 ))
    if [ $(( w_tick % 4 )) -eq 0 ]; then
      jq_info=$(gh api "repos/{owner}/{repo}/actions/runs/$run_id/jobs?per_page=100" --jq '[.jobs[] | select(.status == "queued") | .name] | "\(length)\t\(join(", "))"' 2>/dev/null | tr -d '\r' || true)
      jq_counts=${jq_info%%	*}; [ -n "$jq_counts" ] || jq_counts=0
      rinfo=$(GH_TOKEN="${ADMIN_TOKEN:-${GH_TOKEN:-}}" gh api 'repos/{owner}/{repo}/actions/runners' --jq '"\([.runners[] | select(.status == "online")] | length)\t\([.runners[] | select(.busy)] | length)"' 2>/dev/null || true)
      [ -n "$rinfo" ] && queue_eta "$jq_counts" "${rinfo#*	}" "${rinfo%%	*}" "${QUEUE_JOB_MINUTES:-4}"
      # A batch's full run is a tick too: a request takes effect within two minutes.
      if [ -s "$flaky_dir/batch.members" ]; then requests_tick batch; fi
      # Keep each wait in the local log: when it began, which job, how busy.
      if [ "$jq_counts" -gt 0 ] 2>/dev/null; then
        [ -n "${w_seen:-}" ] || { w_seen=$(date +%s); w_job="run $run_id: ${jq_info#*	}"; }
        w_busy=${rinfo#*	}; w_total=${rinfo%%	*}
      else
        wait_seen_end
      fi
    fi
    # A run still queued after five minutes with no runner online will not
    # start: say so and stop rather than wait out the hour.
    case "$run" in
      *"	queued	"*|*"	queued")
        if [ $(( $(date +%s) - w_start )) -gt 300 ] && [ "$(online_runners)" = 0 ]; then
          echo "Run $run_id has been queued for five minutes and no self-hosted runner is online. Start a runner (scripts/ci/RUNNERS.md), then run the queue again."
          wait_seen_end
          return 3
        fi ;;
    esac
    sleep 30
  done
}

# wait_quiet_main: do not merge while a run on main is in flight, so a
# proof run on main is never canceled by the queue, and a manual run on
# main can expect a quiet main.
wait_quiet_main() {
  q_start=$(date +%s)
  while :; do
    runs=$(gh run list --branch "$base" --limit 10 --json databaseId,headBranch,status,event --jq '.[] | [.databaseId, .headBranch, .status, .event] | @tsv' 2>/dev/null | sed "s/\t$base\t/\tmain\t/")
    [ "$(main_in_flight "$runs")" = yes ] || return 0
    [ $(( $(date +%s) - q_start )) -lt 1200 ] || { echo "A run on $base has been in flight for twenty minutes; merging anyway."; return 0; }
    echo "Holding the merge: a run on $base is in flight."
    sleep 30
  done
}

