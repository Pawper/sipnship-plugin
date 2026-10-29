#!/bin/sh
# The merge queue. Two modes:
#
#   --batch PR...   the default for more than two PRs. Make an integration
#                   branch from main, merge each PR in the order given with
#                   a merge commit, run the type-check and only the test
#                   files that PR touched after each merge, drop a PR that
#                   conflicts or goes red, rebuild the status page, push,
#                   open one PR that closes every carried issue, wait for
#                   the one full CI run, merge it, then run the serial
#                   queue for anything dropped.
#
#   --serial PR...  one at a time, by choice. Merge a green PR without a
#                   re-run when main moved only outside its classes; update
#                   the branch so CI runs again when it moved inside them.
#                   Refused while other pull requests are green and ready
#                   to land with it, unless it says why: --because
#                   migration|conflict|must-land-alone|"reason". The reason
#                   goes into the merge commit's title for the audit.
#
#   --drain         merge everything green, batching, round after round.
#
# After a landing, in every mode, the queue deploys from state and never
# from a flag: when no other open pull request is green and the interval
# in .claude/deploy.json has passed (scripts/ci/deploy-gate.sh), it starts
# the Deploy workflow, or the listed releases where no Deploy run would;
# otherwise it prints "deploy held: ..." and why. A drain deploys once, at
# its end. There is no --deploy: nine serial landings once each carried
# one an agent copied from its last command. The owner forces a deploy
# from the Actions tab, never through the queue.
#
# Usage: sh scripts/ci/merge-queue.sh [--batch | --serial] [--base BRANCH] PR...
#        sh scripts/ci/merge-queue.sh PR [BASE]            (one PR, serial, as before)
#        sh scripts/ci/merge-queue.sh --status             (running or idle, one line)
#        sh scripts/ci/merge-queue.sh --release            (start each listed release once, now)
#
# The last line of .scratch/queue/log for every run is "queue done (exit N);
# lock released", written by the exit trap after the deploy and the lock,
# so a script waiting on the log waits on that line. The lock is logged
# when taken, too.
#
# Two or fewer PRs with no flag run serially. More than two with no flag is
# refused by the require-batch-merge hook; name the mode.
#
# Needs git, gh (signed in), and for batch mode a project with a
# type-check and a test runner. Override the commands with
# QUEUE_TYPECHECK_COMMAND and QUEUE_TEST_COMMAND (the latter takes one
# file as its argument). Turn off "require branches to be up to date" in
# branch protection; this script is the queue. See scripts/ci/QUEUE.md.
set -e
here=$(dirname "$0")
# Run from a copy. sh reads a script as it goes, so an agent switching the
# checkout to another branch mid-drain could change the queue under itself.
# The copy holds scripts/ci and the worktree scripts it calls.
if [ -z "$QUEUE_FROM_COPY" ]; then
  qc=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/queue-$$")
  mkdir -p "$qc/ci" && cp "$here"/* "$qc/ci/" 2>/dev/null
  for f in worktrees.sh worktrees-lib.sh; do if [ -f "$here/../$f" ]; then cp "$here/../$f" "$qc/"; fi; done
  QUEUE_FROM_COPY=1; export QUEUE_FROM_COPY
  exec sh "$qc/ci/merge-queue.sh" "$@"
fi
. "$here/lib.sh"
. "$here/batch-lib.sh"
rules=$(cat "$here/classes.txt")

mode=""
pause_for=""
base="main"
prs=""
because=""
while [ $# -gt 0 ]; do
  case "$1" in
    --batch) mode=batch ;;
    --pause) shift; mode=pause; pause_for=$1 ;;
    --resume) mode=resume ;;
    --status) mode=status ;;
    --release) mode=release ;;
    --serial) mode=serial ;;
    --drain) mode=drain ;;
    --drain-then-deploy) mode=drain; echo "There is no --deploy any more: the queue deploys from state after a landing (scripts/ci/deploy-gate.sh)." ;;
    --deploy) echo "There is no --deploy any more: the queue deploys from state after a landing (scripts/ci/deploy-gate.sh)." ;;
    --because) shift; because=$1 ;;
    --because=*) because=${1#--because=} ;;
    --rounds) shift; rounds=$1 ;;
    --base) shift; base=$1 ;;
    --help|-h) sed -n '2,35p' "$0"; exit 0 ;;
    *[!0-9]*) [ -z "$prs" ] || base=$1 ;;
    *) prs="$prs $1" ;;
  esac
  shift
done
# set_repo_var NAME VALUE: a repository variable, which the scheduled
# drain workflow reads as vars.NAME. Needs a token that can administer the
# repository (the owner's own gh sign-in can).
set_repo_var() {
  gh api -X PATCH "repos/{owner}/{repo}/actions/variables/$1" -f name="$1" -f value="$2" >/dev/null 2>&1 \
    || gh api -X POST "repos/{owner}/{repo}/actions/variables" -f name="$1" -f value="$2" >/dev/null 2>&1
}
iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
case "$mode" in
  release)
    [ -n "$(release_workflows "$(cat .claude/deploy.json 2>/dev/null)")" ] || { echo "No release workflows listed under \"releases\" in .claude/deploy.json."; exit 2; }
    start_releases ask
    exit 0 ;;
  status)
    sl=$(cat ".scratch/queue/lock" 2>/dev/null || true)
    slpid=${sl%%	*}
    salive=no; [ -n "$slpid" ] && kill -0 "$slpid" 2>/dev/null && salive=yes
    queue_status "$(queue_lock_reason "$sl" "$(date +%s)" "$salive")" "$(tail -n 1 ".scratch/queue/log" 2>/dev/null | cut -c1-160)"
    [ -f .claude/deploy.json ] && sh "$here/deploy-gate.sh" "$base" || true
    exit 0 ;;
  pause)
    pu=$(pause_until "$(date +%s)" "$pause_for")
    [ -n "$pu" ] || { echo "Usage: sh scripts/ci/merge-queue.sh --pause 2h (or 45m, or minutes)"; exit 2; }
    if set_repo_var QUEUE_PAUSED_UNTIL "$(iso_utc "$pu")"; then
      echo "The scheduled drain is paused until $(date -d "@$pu" '+%H:%M' 2>/dev/null || iso_utc "$pu") (QUEUE_PAUSED_UNTIL). A drain you run yourself still runs. --resume ends the pause."
      exit 0
    fi
    echo "Could not set the repository variable QUEUE_PAUSED_UNTIL; pausing needs a token that can administer the repository."; exit 1 ;;
  resume)
    set_repo_var QUEUE_PAUSED_UNTIL "" && { echo "The scheduled drain runs again from its next tick."; exit 0; }
    echo "Could not clear QUEUE_PAUSED_UNTIL."; exit 1 ;;
esac

prs=$(batch_order $prs)
[ -n "$prs" ] || [ "$mode" = drain ] || { echo "Usage: sh scripts/ci/merge-queue.sh [--batch | --serial | --drain] [--base BRANCH] PR..." >&2; exit 2; }
count=$(printf '%s\n' "$prs" | wc -l | tr -d ' ')
if [ -z "$mode" ]; then
  if [ "$count" -gt 2 ]; then
    echo "More than two PRs need a mode: --batch (the default choice) or --serial (one at a time, by choice)." >&2
    exit 2
  fi
  mode=serial
fi

# The type-check runs once per package a change touches: the nearest
# folder above each changed file with a tsconfig.json, so a project whose
# app lives in web/ is checked from web/. QUEUE_TYPECHECK_COMMAND, when
# set, runs once from the root as the project's own command.
typecheck=${QUEUE_TYPECHECK_COMMAND:-}
ts_roots=$(git ls-files -- tsconfig.json '*/tsconfig.json' 2>/dev/null | sed 's#/tsconfig\.json$##; s#^tsconfig\.json$#.#')
if [ -z "$typecheck" ] && [ -n "$ts_roots" ]; then typecheck="npx tsc --noEmit"; fi
test_one=${QUEUE_TEST_COMMAND:-"node $here/run-test-file.mjs"}

[ -f "$here/../worktrees-lib.sh" ] && . "$here/../worktrees-lib.sh"
. "$here/run-lib.sh"
tab=$(printf '\t')

# Reading a run. One call for the run, one for its jobs, one for the
# annotations of a job that is stuck, one for our runners. Bounded waits.
wait_minutes=${QUEUE_WAIT_MINUTES:-60}
flaky_dir=.scratch/queue
# Checked-in build output and the command that rebuilds it (see
# scripts/ci/generated-paths.txt): conflicts in these files alone are
# resolved on the batch, not dropped.
gen_cfg=$(cat scripts/ci/generated-paths.txt 2>/dev/null || true)
mkdir -p "$flaky_dir" 2>/dev/null || true

# Staying inside GitHub's API limits. There are two. The hourly quota
# (5,000 REST calls, 5,000 GraphQL points, each shared by every tool and
# agent on the account) was spent once by a fast watch loop. The secondary
# limit, on concurrent and point-heavy GraphQL requests, tripped on a night
# with seven agents and seven open pull requests while the hourly quota
# still showed thousands left: gh pr list, gh pr view and gh pr checks all
# go through GraphQL, and each pass cost seven of them. So the queue makes
# every call through REST (gh api), which has its own budget and no points;
# reads one record per pull request per round and caches it; polls every
# thirty seconds and never faster; reads both budgets before a round (that
# call is free) and sleeps until the reset when the lower one is under
# QUEUE_RATE_FLOOR; backs off when GitHub refuses a call (90 seconds, then
# five minutes, then stops) rather than retrying at once, which makes
# GitHub extend the block; and runs one queue at a time.
gh_err=$flaky_dir/gh.err
# Every line the drain prints is also appended to .scratch/queue/log with
# the time, so a run in the background can be read before it ends.
log_file=$flaky_dir/log
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
pr_rollup() {
  rest_rollup_named "$(gh api "repos/{owner}/{repo}/commits/$1/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)"' 2>"$gh_err" || { rate_stop; echo; })" "${QUEUE_SUMMARY_CHECK:-CI passed}"
}

# One queue at a time. A queue takes .scratch/queue/lock and a second one
# is refused with a line naming the first, so agents do not start parallel
# waits that spend the same budget twice. The batch or serial run a drain
# starts itself is inside the drain's lock. A lock whose process is gone,
# or older than three hours, is a crash's leftover and is taken over.
lock_file=$flaky_dir/lock
have_lock=no
unlock() { if [ "$have_lock" = yes ]; then rm -f "$lock_file" 2>/dev/null; fi; have_lock=no; }
# queue_exit: the one exit trap. The queue never stops without a word:
# under set -e a failing command ends it at once, and twice that was a
# drain exiting 1 with nothing printed, overnight, so nothing merged. A
# drain run in a session also clears its "draining" mark here.
queue_step="starting"
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
publish_now() {
  [ -f "$here/publish-state.sh" ] || return 0
  QUEUE_BASE="$base" QUEUE_DIR="$flaky_dir" sh "$here/publish-state.sh" --mode "$1" ${2:+--open "$2"} 2>>"$flaky_dir/publish.err" | while IFS= read -r pn_l; do say "$pn_l"; done
  return 0
}

queue_exit() {
  qe_rc=$?
  # The last word on the issue: idle, with what landed.
  case "${mode:-}" in drain|serial|batch) publish_now idle ;; esac
  # The console's "what the queue is doing now" line ends with the run.
  : > "$flaky_dir/now" 2>/dev/null || true
  if [ "$qe_rc" -ne 0 ]; then
    echo "merge-queue.sh stopped (exit $qe_rc) during: $queue_step" >&2
    printf '%s %s\n' "$(date '+%H:%M')" "stopped (exit $qe_rc) during: $queue_step" >> "$log_file" 2>/dev/null || true
  fi
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
  if [ -n "$why" ]; then
    last=$(tail -n 1 "$flaky_dir/log" 2>/dev/null | cut -c1-160)
    st=$(cat "$flaky_dir/drain.state" 2>/dev/null | head -n 1)
    [ -n "$st" ] && last="$st; ${last}"
    echo "Another queue is running: $why${last:+; its last line: $last}. Wait for it to finish rather than starting a second one; follow it with tail -f .scratch/queue/log."
    exit 1
  fi
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
    gh api -X POST "repos/{owner}/{repo}/issues" -f title="Flaky test: $test" -f 'labels[]=bug' -f "labels[]=$(state_label ready "$(project_label_form)")" \
      -f body="This test failed and then passed on retry $count times, on pull requests $prs. The merge queue recorded it. An unreliable test is a bug, not weather: fix it or quarantine it with its own issue, do not re-run it again." >/dev/null 2>&1 \
      && { printf '%s\n' "$test" >> "$flaky_dir/flaky-filed.txt"; echo "Filed an issue for the flaky test $test ($count flakes on $prs)."; }
  done
}

# wait_for_run PR BRANCH: wait for the branch's latest run, saying plainly
# what is happening. Returns 0 green, 1 red, 3 gave up.
wait_for_run() {
  w_start=$(date +%s); outage_on=no
  while :; do
    rate_guard
    run=$(latest_run "$2"); run_id=${run%%	*}
    rate_stop
    [ -n "$run_id" ] || { echo "No run found for $2 yet."; sleep 30; continue; }
    # set -e ends the script at a bare failing assignment, so the code is
    # caught here: a pending run (2) once exited the queue with no word.
    code=0; msg=$(diagnose "$run_id") || code=$?
    [ -n "$msg" ] && echo "$msg"
    case $code in
      0) record_flaky "$1" "$run_id" passed
         if [ "$outage_on" = yes ] && [ -n "$QUEUE_OUTAGE_OFF" ]; then sh -c "$QUEUE_OUTAGE_OFF" && echo "Outage switch off again."; fi
         return 0 ;;
      1) record_flaky "$1" "$run_id" failed; return 1 ;;
      3) if [ "$outage_on" = no ] && [ -n "$QUEUE_OUTAGE_ON" ]; then sh -c "$QUEUE_OUTAGE_ON" && { outage_on=yes; echo "Outage switch on for this run."; }; fi ;;
      4) gh run rerun "$run_id" >/dev/null 2>&1 || true ;;
    esac
    if [ $(( $(date +%s) - w_start )) -gt $((wait_minutes * 60)) ]; then
      echo "Waited $wait_minutes minutes for run $run_id; giving up for now. Run the queue again later."
      return 3
    fi
    # Waiting on machines or on tests? Every two minutes, say how many jobs
    # are queued and how busy the runners are.
    w_tick=$(( ${w_tick:-0} + 1 ))
    if [ $(( w_tick % 4 )) -eq 0 ]; then
      jq_counts=$(gh api "repos/{owner}/{repo}/actions/runs/$run_id/jobs?per_page=100" --jq '[.jobs[] | select(.status == "queued")] | length' 2>/dev/null || echo 0)
      rinfo=$(GH_TOKEN="${ADMIN_TOKEN:-${GH_TOKEN:-}}" gh api 'repos/{owner}/{repo}/actions/runners' --jq '"\([.runners[] | select(.status == "online")] | length)\t\([.runners[] | select(.busy)] | length)"' 2>/dev/null || true)
      [ -n "$rinfo" ] && queue_eta "$jq_counts" "${rinfo#*	}" "${rinfo%%	*}" "${QUEUE_JOB_MINUTES:-4}"
    fi
    # A run still queued after five minutes with no runner online will not
    # start: say so and stop rather than wait out the hour.
    case "$run" in
      *"	queued	"*|*"	queued")
        if [ $(( $(date +%s) - w_start )) -gt 300 ] && [ "$(online_runners)" = 0 ]; then
          echo "Run $run_id has been queued for five minutes and no self-hosted runner is online. Start a runner (scripts/ci/RUNNERS.md), then run the queue again."
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

# worktree_of BRANCH: the local worktree that has the branch checked out.
worktree_of() {
  command -v worktree_for_branch >/dev/null 2>&1 || return 0
  worktree_for_branch "$(worktree_branches "$(git worktree list --porcelain)")" "$1"
}

# folder_blocks PR: print why a PR may not be queued when its worktree has
# uncommitted files outside .scratch/. The folder is checked when the PR is
# queued, not after the merge, so a file written minutes before is caught.
folder_blocks() {
  fb_branch=$(pr_field "$1" 1)
  fb_path=$(worktree_of "$fb_branch")
  [ -n "$fb_path" ] || return 0
  fb_dirty=$(dirty_non_scratch "$(git -C "$fb_path" status --porcelain 2>/dev/null)")
  [ -n "$fb_dirty" ] || return 0
  printf 'its worktree has %s uncommitted file(s) outside .scratch/, first: %s\n' \
    "$(printf '%s\n' "$fb_dirty" | wc -l | tr -d ' ')" "$(printf '%s\n' "$fb_dirty" | head -n 1)"
}

# migration_blocks PR: print why a PR may not merge yet when it adds a
# migration that its own copy of the manual does not mark as done. A change
# that needs a migration run merges after the run, not before. The manual
# is SETUP.md or the "manual" line in setup-paths.txt; migrations are the
# "migration" kind in .claude/numbering.txt.
. "$here/numbering-lib.sh"
# fetch_pr_head PR [DIR]: put the pull request's head commit at
# refs/queue/pr-PR (in DIR, default here) and print it. GitHub's pull ref
# (refs/pull/N/head) can lag the branch by half an hour, so when it is not
# the head the pull request reports, the branch itself is fetched. Prints
# nothing and returns 1 when neither has the head yet, with the reason in
# $fph_why.
fetch_pr_head() {
  fph_dir=${2:-.}
  fph_want=$(pr_field "$1" 2)
  git -C "$fph_dir" fetch -q origin "+refs/pull/$1/head:refs/queue/pr-$1" 2>/dev/null || true
  fph_got=$(git -C "$fph_dir" rev-parse -q --verify "refs/queue/pr-$1" 2>/dev/null || true)
  if [ -n "$fph_want" ] && [ "$fph_got" != "$fph_want" ]; then
    fph_branch=$(pr_field "$1" 1)
    if [ -n "$fph_branch" ] && git -C "$fph_dir" fetch -q origin "+refs/heads/$fph_branch:refs/queue/pr-$1" 2>/dev/null; then
      fph_got=$(git -C "$fph_dir" rev-parse -q --verify "refs/queue/pr-$1" 2>/dev/null || true)
    fi
  fi
  if [ -z "$fph_got" ]; then fph_why="its head could not be fetched"; return 1; fi
  if [ -n "$fph_want" ] && [ "$fph_got" != "$fph_want" ]; then
    fph_why="GitHub's copy of it is behind its branch (has $(printf '%.7s' "$fph_got"), the branch is at $(printf '%.7s' "$fph_want")); GitHub usually catches up within minutes, so it waits for the next round, not a failure"
    return 1
  fi
  printf '%s\n' "$fph_got"
}

migration_blocks() {
  [ -f .claude/numbering.txt ] || return 0
  mb_glob=$(numbering_glob "$(cat .claude/numbering.txt)" migration)
  [ -n "$mb_glob" ] || return 0
  mb_manual=SETUP.md
  [ -f "$here/setup-paths.txt" ] && mb_manual=$(setup_manual "$(cat "$here/setup-paths.txt")")
  # A gate that cannot look must block, not pass: a fetch that failed once
  # let two unrun migrations onto main.
  # Fetch the pull request into a ref of its own and read that. Fetching
  # main and the pull request together and then reading FETCH_HEAD names
  # main, the first ref fetched: the gate compared main with itself, saw
  # no migration added, and let three unrun migrations through.
  git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null || { echo "its migrations could not be checked (fetching $base failed); it waits for the next round"; return 0; }
  # The head as the pull request reports it, from its pull ref or, when
  # GitHub's pull ref lags, its branch.
  mb_head=$(fetch_pr_head "$1") || { echo "its migrations could not be checked yet: $fph_why"; return 0; }
  mb_added=$(git diff --name-only --diff-filter=A "origin/$base...$mb_head" 2>/dev/null)
  # Files added under a migrations folder that the glob does not match
  # mean the glob is wrong, and the gate would see nothing; say so.
  mb_stray=$(printf '%s\n' "$mb_added" | tr '\\' '/' | awk '/(^|\/)migrations\//' | while IFS= read -r mb_f; do
    [ -n "$mb_f" ] || continue
    set -f; case "$mb_f" in $mb_glob) ;; *) printf '%s\n' "$mb_f" ;; esac; set +f
  done | head -n 1)
  if [ -n "$mb_stray" ]; then echo "it adds $mb_stray under a migrations folder that the migration glob in .claude/numbering.txt ($mb_glob) does not match; fix the glob so the gate can see it"; return 0; fi
  mb_pending=$(pending_migrations "$(git show "$mb_head:$mb_manual" 2>/dev/null)" "$mb_added" "$mb_glob")
  [ -n "$mb_pending" ] || return 0
  printf '%s\n' "$mb_pending" | head -n 1 | awk -F'\t' -v m="$mb_manual" '{ printf "it adds migration %s, which is %s in %s; run it, mark it Done in the manual on this branch, then queue it again\n", $1, $2, m }'
}

# sync_worktree BRANCH: never move a branch from outside its worktree. When
# the queue advances a branch on the remote, bring the worktree's files
# along, so the folder does not look full of edits it never made.
sync_worktree() {
  sw_path=$(worktree_of "$1")
  [ -n "$sw_path" ] || return 0
  git -C "$sw_path" pull -q --ff-only >/dev/null 2>&1 || echo "note: the worktree at $sw_path could not fast-forward; update it by hand before working there"
}

# serial_one PR: today's behavior for one PR.
# pr_held PR: why this pull request is held, or nothing.
pr_held() {
  held_reason "$(gh api "repos/{owner}/{repo}/issues/$1/labels" --jq '.[].name' 2>/dev/null)" "$(gh api "repos/{owner}/{repo}/pulls/$1" --jq '.body // ""' 2>/dev/null)"
}

serial_one() {
  pr=$1
  # Held: not merged, unless a person ran --serial with a reason.
  hw=$(pr_held "$pr")
  if [ -n "$hw" ] && { [ -n "$QUEUE_IN_DRAIN" ] || [ -z "$because" ]; }; then batch_line "$pr" "not merged" "$hw; remove the hold, or merge it with --serial $pr --because \"why\""; return 0; fi
  why=$(folder_blocks "$pr"); [ -n "$why" ] || why=$(migration_blocks "$pr")
  if [ -n "$why" ]; then batch_line "$pr" "refused" "$why"; return 0; fi
  if ! fetch_base "pull/$pr/head"; then
    batch_line "$pr" "not merged" "could not fetch $base; it is tried again next round"
    printf '%s\n' "$pr" >> "$flaky_dir/untried" 2>/dev/null || true
    return 0
  fi
  head=$(pr_field "$pr" 2)
  hb=$(pr_field "$pr" 1)
  merge_base=$(git merge-base "origin/$base" "$head")
  pr_classes=$(classify_paths "$(git diff --name-only "$merge_base" "$head")" "$rules")
  main_classes=$(classify_paths "$(git diff --name-only "$merge_base" "origin/$base")" "$rules")
  # A conflict with main is said as one, with its files, instead of
  # "updated" round after round while nothing can merge.
  if [ "$(mergeable_word "$(pr_field "$pr" 5)")" = CONFLICTING ] || ! git merge-tree --write-tree origin/"$base" "$head" >/dev/null 2>&1; then
    files=$(git merge-tree --write-tree --name-only origin/"$base" "$head" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    if [ "$(mergeable_word "$(pr_field "$pr" 5)")" = CONFLICTING ] || [ -n "$files" ]; then
      batch_line "$pr" "not merged" "$(conflict_line "$files")"
      notify_conflict "$pr" "$files" main
      return 0
    fi
  fi
  if [ "$(pr_rollup "$head")" != green ]; then
    run=$(latest_run "$hb"); run_id=${run%%	*}
    run_status=$(printf '%s' "$run" | cut -f2)
    rate_stop
    why="not green yet, nothing merged"
    code=2
    if [ -n "$run_id" ] && [ "$run_status" != completed ] && [ -n "$run_status" ]; then
      # Re-run (gh run rerun --failed): the old attempt's red checks still
      # show on the commit for a few seconds while the new attempt starts.
      # A run that is not completed is pending, whatever its old checks say.
      code=2; msg="its run is $run_status (a new attempt)"
    elif [ -n "$run_id" ]; then
      code=0; msg=$(diagnose "$run_id") || code=$?
      case $code in
        1) record_flaky "$pr" "$run_id" failed; why="$msg" ;;
        3) why="$msg" ;;
        4)
          # A job cancelled before a runner took it is not a failure:
          # re-run it and wait, rather than give up.
          gh run rerun "$run_id" >/dev/null 2>&1 || true
          batch_line "$pr" "waiting" "$msg; re-ran it and waiting for the result"
          if wait_for_run "$pr" "$hb"; then rm -f "$flaky_dir/pr-$pr.tsv"; serial_one "$pr"; return 0; fi
          return 0 ;;
      esac
    fi
    # Run by hand on a pull request whose checks are still running,
    # --serial waits for them and merges, once, rather than leaving its
    # caller to wait and run it again. A red run is said, never waited on;
    # a drain moves on and comes back next round.
    if [ -z "$QUEUE_IN_DRAIN" ] && [ -z "${serial_waited:-}" ] && { [ "$code" = 0 ] || [ "$code" = 2 ]; }; then
      serial_waited=1
      batch_line "$pr" "waiting" "its checks are still running; waiting for them (up to ${QUEUE_WAIT_MINUTES:-60} minutes), then merging"
      if wait_for_run "$pr" "$hb"; then rm -f "$flaky_dir/pr-$pr.tsv" 2>/dev/null; serial_one "$pr"; return 0; fi
    fi
    batch_line "$pr" "waiting" "$why"
    return 0
  fi
  nr=$(needs_rerun "$pr_classes" "$main_classes" "$(rerun_free_classes "$rules")")
  ms=""; [ "$nr" = yes ] && ms=$(main_state)
  merged_why="main moved only outside its classes"
  [ "$nr" = yes ] && merged_why="main moved in its classes, but it merges cleanly and main is green; the full run on main is the gate"
  if [ "$(rerun_decision "$nr" "$ms" "${QUEUE_RERUN:-green-main}")" = update ]; then
    if ! gh api -X PUT "repos/{owner}/{repo}/pulls/$pr/update-branch" >/dev/null 2>"$gh_err"; then
      rate_stop
      case "$(cat "$gh_err" 2>/dev/null)" in
        *onflict*) batch_line "$pr" "not merged" "$(conflict_line "$(git merge-tree --write-tree --name-only origin/"$base" "$head" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')")" ;;
        *) batch_line "$pr" "not merged" "GitHub refused to update the branch: $(head -n 1 "$gh_err" 2>/dev/null)" ;;
      esac
      return 0
    fi
    sync_worktree "$hb"
    batch_line "$pr" "updated" "main moved in its classes (PR: ${pr_classes:-none}; main: ${main_classes:-none}) and main is ${ms:-not known to be green}, so CI runs again"
    # Run by hand, --serial waits for that run and merges, rather than
    # leaving its caller to loop; once only, so a main that keeps moving
    # is said, not chased. A drain moves on and comes back next round.
    if [ -z "$QUEUE_IN_DRAIN" ] && [ -z "${serial_refreshed:-}" ]; then
      serial_refreshed=1
      sleep 20
      rm -f "$flaky_dir/pr-$pr.tsv" 2>/dev/null
      if wait_for_run "$pr" "$hb"; then serial_one "$pr"; fi
    fi
    return 0
  fi
  head_branch=$hb
  why=$(migration_blocks "$pr")
  if [ -n "$why" ]; then batch_line "$pr" "refused" "$why"; return 0; fi
  rq=$(required_on "$head")
  # The same for the required check alone: by hand, wait for it once.
  if [ "$rq" = pending ] && [ -z "$QUEUE_IN_DRAIN" ] && [ -z "${serial_waited:-}" ]; then
    serial_waited=1
    batch_line "$pr" "waiting" "the required check \"${QUEUE_SUMMARY_CHECK:-CI passed}\" is still running; waiting for it, then merging"
    wait_required "$head" >/dev/null 2>&1 || true
    rq=$(required_on "$head")
  fi
  if [ "$rq" != passed ]; then
    batch_line "$pr" "waiting" "the required check \"${QUEUE_SUMMARY_CHECK:-CI passed}\" is $rq on its head commit; GitHub refuses the merge until it passes"
    return 0
  fi
  record_flaky "$pr" "" passed
  wait_quiet_main
  gh api -X PUT "repos/{owner}/{repo}/pulls/$pr/merge" -f merge_method=squash -f commit_title="$(serial_title "$(pr_field "$pr" 3)" "$pr" "${because:-alone}")" >/dev/null 2>"$gh_err" || { rate_stop; batch_line "$pr" "not merged" "GitHub refused the merge: $(head -n 1 "$gh_err" 2>/dev/null)"; return 0; }
  batch_line "$pr" "merged serially" "$merged_why"
  tidy_worktree "$head_branch"
}

# typecheck_ok PATHS [DIR]: the type-check, run once in each package the
# change touches (the nearest folder above each changed file with a
# tsconfig.json), or once from the root when QUEUE_TYPECHECK_COMMAND names
# the project's own command. DIR is the checkout to run in (default here).
# Returns non-zero on the first red package, with its output in
# .scratch/queue/typecheck.err so the caller can name the first error.
typecheck_ok() {
  tc_root=${2:-.}
  : > "$flaky_dir/typecheck.err"
  if [ -n "$QUEUE_TYPECHECK_COMMAND" ] || [ -z "$ts_roots" ]; then (cd "$tc_root" && sh -c "$typecheck") >"$flaky_dir/typecheck.err" 2>&1; return $?; fi
  tc_dirs=$(printf '%s\n' "$1" | while IFS= read -r tc_f; do if [ -n "$tc_f" ]; then nearest_root "$tc_f" "$ts_roots"; fi; done | sort -u)
  for tc_d in $tc_dirs; do
    [ -f "$tc_root/$tc_d/tsconfig.json" ] || continue
    (cd "$tc_root/$tc_d" && sh -c "$typecheck") >"$flaky_dir/typecheck.err" 2>&1 || return 1
  done
  return 0
}

# why_red PR: the failing check runs on the pull request's head, by name,
# and the first lines of each job's log that look like an error, so
# "failed CI twice" comes with its cause instead of three more calls.
why_red() {
  wr_sha=$(pr_field "$1" 2)
  wr_jobs=$(gh api "repos/{owner}/{repo}/commits/$wr_sha/check-runs?per_page=100" --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "startup_failure" or .conclusion == "action_required" or .conclusion == "timed_out") | "\(.name)\t\(.id)"' 2>/dev/null || true)
  [ -n "$wr_jobs" ] || { echo "    (no failing check run on its head commit now; it may have gone green since)"; return 0; }
  printf '%s\n' "$wr_jobs" | while IFS="$tab" read -r wr_name wr_id; do
    [ -n "$wr_name" ] || continue
    wr_lines=$(gh api "repos/{owner}/{repo}/actions/jobs/$wr_id/logs" 2>/dev/null | tr -d '\r' | grep -E 'error|Error|FAIL|AssertionError' | grep -v '^[[:space:]]*$' | head -n 3 | cut -c1-160)
    if [ -n "$wr_lines" ]; then
      echo "    $wr_name failed:"
      printf '%s\n' "$wr_lines" | sed 's/^/      /'
    else
      echo "    $wr_name failed (its log could not be read; open the run)"
    fi
  done
}

# tidy_worktree BRANCH: remove the worktree of a branch that just merged,
# when it is clean. The branch itself is kept. Quiet when there is none.
tidy_worktree() {
  [ -n "$1" ] && [ -f "$here/../worktrees.sh" ] || return 0
  sh "$here/../worktrees.sh" prune --apply --branch "$1" 2>/dev/null | grep '^removed' || true
}

# Drain: merge everything that is green, round after round, so nobody
# writes their own loop. Each round reads every open pull request in one
# call, merges the green ones (as a batch whenever two or more are green), and waits
# for the running ones. It stops when nothing is green and nothing is
# running, when nothing new turned green, after --rounds rounds (default
# six), or after QUEUE_DRAIN_MINUTES (default ninety).
take_lock
# start_releases WHY: the release workflows listed in .claude/deploy.json,
# each started once, unless "releaseOn" is "ask" and WHY is a landing, or
# the workflow is turned off. A turned-off release is a decision, not an
# error: one project holds releases until its owner says go, and the queue
# once tried to start both after an unrelated merge.
start_releases() {
  sr_cfg=$(cat .claude/deploy.json 2>/dev/null)
  sr_on=$(release_on "$sr_cfg")
  for sr_f in $(release_workflows "$sr_cfg"); do
    sr_state=$(gh api "repos/{owner}/{repo}/actions/workflows/$sr_f" --jq .state 2>/dev/null) || sr_state=""
    sr_why=$(release_hold "$sr_state" "$sr_on" "$1")
    if [ -n "$sr_why" ]; then say "release held: $sr_f $sr_why"; continue; fi
    gh api -X POST "repos/{owner}/{repo}/actions/workflows/$sr_f/dispatches" -f ref="$base" >/dev/null 2>&1 \
      && say "Started the release workflow $sr_f." || say "Could not start $sr_f; run it from the Actions tab."
  done
}

# Defined before the drain, which calls it at its end: defined after it,
# the drain ended "deploy_if_due: command not found" (exit 127) every time.
# deploy_if_due BEGIN_SHA: after a landing, the same in every mode. When main
# moved since BEGIN_SHA and the project deploys on a schedule, start the
# Deploy workflow now rather than at the next hour; the guard path deploys
# from Git by itself. Release channels (store uploads, test distributions)
# follow Deploy; where no Deploy run starts them, the ones listed under
# "releases" in .claude/deploy.json are started here, once. A --serial
# run once ended "queue done" with no deploy started: only the drain did this.
deploy_if_due() {
  d_end=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
  if [ "$d_end" = "$1" ]; then say "Nothing merged, so nothing to deploy."; return 0; fi
  [ -f .claude/deploy.json ] || { say "No .claude/deploy.json; main deploys on its own."; return 0; }
  # The gate: no other green pull request waiting, and the interval passed.
  if gate=$(sh "$here/deploy-gate.sh" "$base" 2>/dev/null); then :; else say "${gate:-deploy: held} (the Deploy workflow's own dispatch in Actions forces one)"; return 0; fi
  # Nothing that ships changed since the last deploy (or since this run
  # began, when none is recorded): start nothing. A template sync that
  # touched only scripts/ci and workflows once started a web build and two
  # Android builds. A later landing that ships deploys everything since.
  git fetch -q origin "$base" 2>/dev/null || true
  d_from=$(git ls-remote origin refs/deploy/production 2>/dev/null | cut -f1)
  if [ -z "$d_from" ] || ! git cat-file -e "$d_from^{commit}" 2>/dev/null; then d_from=$1; fi
  if [ "$(sh "$here/deploy-gate.sh" --ships "$d_from" "$d_end" 2>/dev/null)" = skip ]; then
    say "deploy: skipped, nothing that ships changed since $(printf '%s' "$d_from" | cut -c1-7)"
    return 0
  fi
  say "$gate"
  if [ -f .github/workflows/deploy.yml ] && grep -q '"runner"\|"vercel"' .claude/deploy.json 2>/dev/null; then
    # A project that shows a build id (scripts/ci/build-id.sh) gets it named
    # here, so the line matches what Settings will show.
    d_build=""; if [ -f scripts/ci/build-id.sh ]; then d_build=$(sh scripts/ci/build-id.sh "$d_end" 2>/dev/null | head -n 1); fi
    gh api -X POST "repos/{owner}/{repo}/actions/workflows/deploy.yml/dispatches" -f ref="$base" >/dev/null 2>&1 && say "Started the Deploy workflow for what was merged${d_build:+, build $d_build}." || say "$(deploy_refused_message "$base")"
    return 0
  fi
  say "This project deploys from Git (the guard path) or has no Deploy workflow; main deploys on its own."
  start_releases landing
}

if [ "$mode" = drain ]; then
  rounds=${rounds:-6}
  drain_minutes=${QUEUE_DRAIN_MINUTES:-90}
  # A drain started in a session says so, so the scheduled drain skips
  # instead of racing it; the mark is cleared when this drain ends.
  if [ -z "${GITHUB_ACTIONS:-}" ]; then
    set_repo_var QUEUE_LOCAL_DRAIN_UNTIL "$(iso_utc $(( $(date +%s) + drain_minutes * 60 )))" || true
    local_drain_mark=yes
  fi
  d_start=$(date +%s); round=0; tried=""; retried=""; attention=""; last_look=""
  d_begin=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
  while [ "$round" -lt "$rounds" ]; do
    round=$((round + 1))
    queue_step="drain round $round: reading the open pull requests"
    rate_guard
    # One REST list, then one metadata call and one check-runs call per
    # open pull request, each on the REST budget and cached for the round.
    # A listing that fails is an error, never an empty queue: one run read
    # "nothing left to merge" with fourteen open because the call had failed.
    tries=0
    while :; do
      if listed=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, (.draft | tostring), .head.sha, .base.ref] | @tsv' 2>"$gh_err"); then break; fi
      l_err=$(head -n 1 "$gh_err" 2>/dev/null | tr -d '\r' | cut -c1-120)
      rate_stop
      tries=$((tries + 1))
      if [ "$tries" -ge 3 ]; then
        say "Could not list the open pull requests after three tries (${l_err:-no detail}). Nothing was merged; this is a failed listing, not an empty queue."
        exit 1
      fi
      say "Listing the open pull requests failed (${l_err:-no detail}); trying again in 60 seconds."
      sleep 60
    done
    queue_step="drain round $round: reading holds"
    # Held pull requests (a queue:hold label or a "Queue: hold" line) wait,
    # however green.
    held=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | "\(.number)\t\([.labels[].name] | join(","))\t\((.body // "") | gsub("[\r\n]+"; " | "))"' 2>/dev/null \
      | while IFS="$tab" read -r h_num h_labels h_body; do
        h_why=$(held_reason "$(printf '%s' "$h_labels" | tr ',' '\n')" "$(printf '%s' "$h_body" | sed 's/ | /\
/g')")
        if [ -n "$h_why" ]; then printf '%s ' "$h_num"; fi
      done)
    if [ -n "$held" ]; then
      [ "$held" = "${last_held:-}" ] || say "round $round: held, not merged:$(printf ' #%s' $held)"
      last_held=$held
      listed=$(drop_members "$listed" "$held")
    fi
    queue_step="drain round $round: settling open batches"
    # Open batches: their members are theirs, not the drain's. A batch one of
    # whose members has landed on its own no longer matches main; close it.
    members=""; settled=""
    for bp in $(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select((.body // "") | (contains("<!-- merge-queue:batch -->") or startswith("One integration run for the pull requests below"))) | .number' 2>/dev/null); do
      bm=$(batch_members "$(gh api "repos/{owner}/{repo}/pulls/$bp" --jq '.body // ""' 2>/dev/null)")
      landed=""
      for m in $bm; do if [ "$(gh api "repos/{owner}/{repo}/pulls/$m" --jq '.merged' 2>/dev/null)" = true ]; then landed="$landed #$m"; fi; done
      # Only one queue runs and a batch finishes within its round, so an
      # open batch here was left by an earlier run. Settle it.
      bstate=$(required_on "$(gh api "repos/{owner}/{repo}/pulls/$bp" --jq .head.sha 2>/dev/null)")
      if [ -n "$landed" ]; then
        gh api -X POST "repos/{owner}/{repo}/issues/$bp/comments" -f body="Closed by the queue: member(s)$landed landed on their own, so this batch no longer matches main. The rest are queued again on their own." >/dev/null 2>&1 || true
        gh api -X PATCH "repos/{owner}/{repo}/pulls/$bp" -f state=closed >/dev/null 2>&1 && say "round $round: closed batch #$bp, since$landed landed on their own."
        settled="$settled $bp $(printf '%s' "$landed" | tr -d '#')"
      elif [ "$bstate" = passed ] && bsha=$(gh api -X PUT "repos/{owner}/{repo}/pulls/$bp/merge" -f merge_method=merge --jq .sha 2>/dev/null); then
        say "round $round: merged batch #$bp, left green by an earlier run (members:$(printf ' #%s' $bm))."
        settled="$settled $bp $bm"
        for m in $bm; do gh api -X POST "repos/{owner}/{repo}/issues/$m/comments" -f body="Merged into $base in batch #$bp (commit $bsha), with its history kept. GitHub may show this pull request as closed rather than merged; its changes are on $base." >/dev/null 2>&1 || true; done
      elif [ "$bstate" = failed ]; then
        gh api -X POST "repos/{owner}/{repo}/issues/$bp/comments" -f body="Closed by the queue: left open by an earlier run with its required check failed. Its members are queued again on their own." >/dev/null 2>&1 || true
        gh api -X PATCH "repos/{owner}/{repo}/pulls/$bp" -f state=closed >/dev/null 2>&1 && say "round $round: closed batch #$bp, whose required check failed; its members are queued again."
        settled="$settled $bp"
      else
        # Still running: its members wait with it rather than race it.
        members="$members $bm $bp"
        say "round $round: batch #$bp is still running CI; its members$(printf ' #%s' $bm) wait for it."
      fi
    done
    queue_step="drain round $round: reading each pull request's state"
    listed=$(drop_members "$listed" "$members $settled")
    open=$(printf '%s\n' "$listed" | while IFS="$tab" read -r o_num o_draft o_sha o_base; do
      [ -n "$o_num" ] || continue
      # After main moves GitHub says "unknown" for a few seconds while it
      # recomputes; read again before treating the pull request as not ready.
      o_mw=$(mergeable_word "$(pr_field "$o_num" 5)"); o_try=0
      while [ "$o_mw" = UNKNOWN ] && [ "$o_try" -lt 3 ]; do
        sleep 4; rm -f "$flaky_dir/pr-$o_num.tsv" 2>/dev/null
        o_mw=$(mergeable_word "$(pr_field "$o_num" 5)"); o_try=$((o_try + 1))
      done
      printf '%s\t%s\t%s\t%s\t%s\n' "$o_num" "$o_draft" "$o_mw" "$(pr_rollup "$o_sha")" "$o_base"
    done)
    rate_ok
    queue_step="drain round $round: re-running failed jobs"
    # A red pull request gets one retry of its failed jobs; a second red,
    # or a conflict, is collected and named when the drain ends.
    for r in $(drain_retry "$open" "$base" "$retried"); do
      rb=$(pr_field "$r" 1)
      rid=$(latest_run "$rb"); rid=${rid%%	*}
      if [ -n "$rid" ] && gh run rerun "$rid" --failed >/dev/null 2>&1; then
        say "round $round: #$r failed or had a job cancelled; re-running its failed jobs (a cancelled job, every round; a failure, once)."
      fi
      retried="$retried $r"
    done
    attention=$(printf '%s
%s
' "$attention" "$(drain_attention "$open" "$base" "$retried")" | sed '/^$/d' | sort -u -n)
    printf '%s\n' "$open" > "$flaky_dir/open.tsv" 2>/dev/null || true
    printf '%s\n' "$attention" | sed '/^$/d' | awk -v b="$base" '{ printf "%s\tfailed CI twice\tits checks stay red\t\n", $1 }' > "$flaky_dir/attention.tsv" 2>/dev/null || true
    publish_now draining "$flaky_dir/open.tsv"
    queue_step="drain round $round: choosing what to merge"
    pick=$(drain_candidates "$open" "$base" "$tried")
    waiting=$(drain_waiting "$open" "$base" "$retried")
    n=$(printf '%s\n' "$pick" | sed '/^$/d' | wc -l | tr -d ' ')
    elapsed=$(( $(date +%s) - d_start ))
    if [ "$n" -gt 0 ] && [ "$(drain_hold "$n" "$waiting")" = yes ] && [ "$elapsed" -lt $((drain_minutes * 60)) ]; then
      # A serial merge now would move main under the ones still running
      # and send them back round CI; the batch after it would be empty.
      say "round $round: $n green, $waiting still running CI; holding the serial merge until they finish, so it does not send them back round CI."
      round=$((round - 1))
      sleep 120
      continue
    fi
    # Waiting on CI or on a machine? When every pending pull request's
    # checks are queued and no runner is online, waiting is pointless.
    queued_only=no
    if [ "$waiting" -gt 0 ]; then
      statuses=$(printf '%s\n' "$open" | awk -F'\t' -v b="$base" '$2 == "false" && $5 == b && $4 == "pending" { print $1 }' | while read -r w_num; do
        w_sha=$(printf '%s\n' "$listed" | awk -F'\t' -v n="$w_num" '$1 == n { print $3; exit }')
        if [ -n "$w_sha" ]; then gh api "repos/{owner}/{repo}/commits/$w_sha/check-runs?per_page=100" --jq '.check_runs[].status' 2>/dev/null; fi
      done)
      queued_only=$(checks_queued_only "$statuses")
      stall=$(runner_stall "$queued_only" "$(online_runners)")
      printf 'round %s of %s; %s pull request(s) waiting%s\n' "$round" "$rounds" "$waiting" "$( [ "$queued_only" = yes ] && echo ' on queued checks, which no runner has taken')" > "$flaky_dir/drain.state"
      if [ "$stall" = stop ]; then
        say "round $round: $waiting pull request(s) wait on checks that are all queued, and no self-hosted runner is online. Start a runner (scripts/ci/RUNNERS.md), then run --drain again; waiting would change nothing."
        break
      elif [ "$stall" = unknown ] && [ -z "$said_unknown" ]; then
        say "round $round: the checks are all queued, and the runners could not be read (set ADMIN_TOKEN to let the queue see them); if none is online, start one."
        said_unknown=1
      fi
    fi
    if [ "$n" -eq 0 ]; then
      if [ "$waiting" -gt 0 ] && [ "$elapsed" -lt $((drain_minutes * 60)) ]; then
        say "round $round: nothing new is green; $waiting pull request(s) still running CI, waiting two minutes."
        sleep 120
        continue
      fi
      if [ "$waiting" -gt 0 ]; then say "round $round: nothing new is green, and $waiting still running after $drain_minutes minutes; stopping."; break; fi
      # One more look a minute later before saying nothing is left: a pull
      # request whose checks turned green just after this round's read, or
      # had not reported yet, was once left behind with the queue "done".
      if [ -z "$last_look" ]; then
        last_look=1
        say "round $round: nothing green right now; one more look in a minute before stopping."
        sleep 60
        round=$((round - 1))
        continue
      fi
      say "round $round: nothing left to merge."
      break
    fi
    last_look=""
    queue_step="drain round $round: merging"
    say "round $round: $n green pull request(s): $(printf '%s' "$pick" | tr '\n' ' ')"
    QUEUE_IN_DRAIN=1; export QUEUE_IN_DRAIN
    : > "$flaky_dir/untried" 2>/dev/null || true
    if [ "$n" -ge 2 ]; then sh "$0" --batch --base "$base" $pick 2>&1 | tee -a "$log_file" || true; else sh "$0" --serial --base "$base" $pick 2>&1 | tee -a "$log_file" || true; fi
    # A pull request the round could not even try (main would not fetch)
    # is not tried: it stays in for the next round.
    untried=$(tr -d '\r' < "$flaky_dir/untried" 2>/dev/null | tr '\n' ' ')
    for t in $pick; do
      case " $untried " in *" $t "*) ;; *) tried="$tried $t" ;; esac
    done
    if [ -n "$(printf '%s' "$untried" | tr -d ' ')" ]; then say "round $round: main could not be fetched; trying$(printf ' #%s' $untried) again next round."; fi
    if [ $(( $(date +%s) - d_start )) -ge $((drain_minutes * 60)) ]; then
      say "Drained for $drain_minutes minutes; stopping. Run --drain again to go on."
      break
    fi
  done
  say "drain rounds done"
  deploy_if_due "$d_begin"
  # Re-read each one before calling it a failure: a pull request red
  # earlier in the drain may be green, or only cancelled, by now.
  still=""
  if [ -n "$attention" ]; then
    rm -f "$flaky_dir/pr-"*.tsv 2>/dev/null
    still=$(printf '%s\n' "$attention" | while IFS="$tab" read -r a_num a_why; do
      [ -n "$a_num" ] || continue
      case "$a_why" in
        *"failed CI twice"*)
          now=$(pr_rollup "$(pr_field "$a_num" 2)")
          if [ "$now" = red ]; then printf '%s\t%s\n' "$a_num" "$a_why"
          else say "  #$a_num was red earlier in this drain and is $now now; not a failure."; fi ;;
        *) printf '%s\t%s\n' "$a_num" "$a_why" ;;
      esac
    done)
  fi
  if [ -n "$still" ]; then
    say "Needs attention:"
    printf '%s\n' "$still" | while IFS="$tab" read -r a_num a_why; do
      [ -n "$a_num" ] || continue
      say "  #$a_num $a_why"
      case "$a_why" in *"failed CI twice"*) why_red "$a_num" | tee -a "$log_file" ;; esac
    done
    exit 1
  fi
  exit 0
fi

# notify_conflict PR FILES WITH: comment on the pull request and label it
# state:blocked, once per head commit, so the owning agent finds the
# conflict on its next session instead of it waiting until someone looks.
notify_conflict() {
  nc_sha=$(pr_field "$1" 2)
  nc_seen="$flaky_dir/noticed"
  grep -qx "$1 $nc_sha" "$nc_seen" 2>/dev/null && return 0
  gh api -X POST "repos/{owner}/{repo}/issues/$1/comments" -f body="$(conflict_notice "$2" "$3" "${4:-}")" >/dev/null 2>&1 || return 0
  nc_cur=$(gh api "repos/{owner}/{repo}/issues/$1/labels" --jq '.[].name' 2>/dev/null || true)
  nc_label=$(state_label blocked "$(project_label_form)")
  state_labels_json "$nc_cur" "$nc_label" | gh api -X PUT "repos/{owner}/{repo}/issues/$1/labels" --input - >/dev/null 2>&1 || true
  echo "$1 $nc_sha" >> "$nc_seen"
  say "  #$1: commented with the conflicting files and labeled it $nc_label."
}


# ready_others EXCLUDE: the open pull requests aimed at the base, not
# drafts, green and not conflicting with main, other than EXCLUDE.
ready_others() {
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, (.draft | tostring), .head.sha, .base.ref] | @tsv' 2>/dev/null \
    | while IFS="$tab" read -r r_num r_draft r_sha r_base; do
      [ -n "$r_num" ] && [ "$r_draft" = false ] && [ "$r_base" = "$base" ] || continue
      case " $1 " in *" $r_num "*) continue ;; esac
      [ "$(pr_rollup "$r_sha")" = green ] || continue
      [ "$(mergeable_word "$(pr_field "$r_num" 5)")" != CONFLICTING ] || continue
      printf '%s ' "$r_num"
    done
}

if [ "$mode" = serial ]; then
  # The rule lives here, not only in a hook on the command line: a script
  # that wraps the queue hides the call from the hook. Run by a drain or a
  # batch, the choice was already made.
  if [ -z "$QUEUE_IN_DRAIN" ] && [ -z "$because" ]; then
    why=$(serial_refusal "$(ready_others "$(printf '%s ' $prs)")" "$because")
    if [ -n "$why" ]; then say "Refused --serial: $why"; exit 2; fi
  fi
  [ -n "$because" ] || { [ -n "$QUEUE_IN_DRAIN" ] && because=drain; }
  s_begin=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
  for pr in $prs; do serial_one "$pr"; done
  if [ -z "$QUEUE_IN_DRAIN" ]; then deploy_if_due "$s_begin"; fi
  exit 0
fi

b_begin=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
# Batch mode. The batch is built in its own worktree, never in the main
# checkout, so a person working there is not switched onto the batch
# branch under their feet. QUEUE_WORKTREE names the folder; the default is
# a sibling of the repository called <repo>-wt-batch, which is reused from
# one batch to the next. Each package's node_modules is linked from the
# main checkout when the worktree has none, so nothing is installed twice.
if ! fetch_base; then
  # Not tried: the drain takes these again next round rather than calling
  # them done.
  printf '%s\n' $prs >> "$flaky_dir/untried" 2>/dev/null || true
  echo "Nothing merged this round: main could not be fetched. These are tried again:$(printf ' #%s' $prs)"
  exit 1
fi
day=$(date +%Y-%m-%d)  # the owner's local day, like every date in the repository
n=1
stamp=$(date +%H%M%S)
branch=$(batch_branch_name "$day" "$n" "$stamp")
while git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; do
  n=$((n + 1)); branch=$(batch_branch_name "$day" "$n" "$stamp")
done
# The main checkout is the first worktree git lists, whatever folder the
# queue was started from; its node_modules are the ones to link, and the
# batch worktree is named after it.
main_dir=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' | tr -d '\r')
[ -n "$main_dir" ] && [ -d "$main_dir" ] || main_dir=$(pwd)
wt=${QUEUE_WORKTREE:-"$(cd "$main_dir/.." && pwd)/$(basename "$main_dir")-wt-batch"}
if [ -e "$wt/.git" ]; then
  git -C "$wt" checkout -q -B "$branch" "origin/$base"
else
  git worktree add -q -B "$branch" "$wt" "origin/$base"
fi
# ensure_modules: every package in the batch checkout has the packages its
# own lockfile names. Where the lockfile is the main checkout's, its
# node_modules are linked (a junction on Windows, a symlink elsewhere), so
# nothing is installed twice. Where it differs (main moved a dependency or
# a workspace package, or a member changed one), the link is removed
# (only the link: never the files behind it) and the project's install
# runs there, QUEUE_INSTALL_COMMAND or "npm ci". A workspace root (see ensure_workspace) is one unit. A stale link once made a
# green main type-check red "before any merge".
mod_hash() { [ -f "$1" ] && git hash-object "$1" 2>/dev/null || echo none; }
# pkg_hash DIR PACKAGE_DIR: the lockfile's hash plus the tree hash of every
# "file:" dependency of DIR's package.json at that checkout's HEAD, so a
# repack of packages/core that lands on main without touching the lockfile
# still counts as a change. A batch once refused to start with "main is red"
# on a type error main did not have: its node_modules held the old copy.
pkg_hash() {
  ph_lock=$(mod_hash "$1/$2/package-lock.json")
  ph_trees=$(for ph_p in $(file_deps "$(cat "$1/$2/package.json" 2>/dev/null)"); do
    git -C "$1" rev-parse -q --verify "HEAD:$2/$ph_p" 2>/dev/null || echo none
  done | paste -sd, -)
  printf '%s%s\n' "$ph_lock" "${ph_trees:+,$ph_trees}"
}
is_link() { [ -e "$1" ] && [ "$(cd -P "$1" 2>/dev/null && pwd -P)" != "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1")" ]; }
unlink_dir() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) cmd //c rmdir "$(cygpath -w "$1")" >/dev/null 2>&1 ;;
    *) unlink "$1" 2>/dev/null ;;
  esac
}
# link_dir TARGET LINK. Git Bash rewrites "/J" as a path unless told not
# to, and mklink then failed with "Invalid switch", quietly.
link_dir() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' cmd /c mklink /J "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null 2>&1 ;;
    *) ln -s "$1" "$2" 2>/dev/null ;;
  esac
}
install_here() { # DIR HASH
  echo "Installing packages in $1 (its lockfile or a file: package is not what the installed packages came from)."
  if (cd "$1" && sh -c "${QUEUE_INSTALL_COMMAND:-npm ci --no-audit --no-fund}") >/dev/null 2>"$flaky_dir/install.err"; then
    printf '%s\n' "$2" > "$1/node_modules/.queue-lock-hash" 2>/dev/null || true
  else
    echo "  the install failed: $(tail -n 1 "$flaky_dir/install.err" 2>/dev/null)"
    echo "$1: the install failed" >> "$flaky_dir/modules.stale"
  fi
}

# A workspace is one unit: the root lockfile plus each member's package.json
# is the hash, the install runs once from the root, and the root's and each
# member's node_modules are linked when the hash is main's.
ensure_workspace() { # KIND
  ew_hash=$(workspace_hash "$wt" "$1")
  ew_main=$(workspace_hash "$main_dir" "$1")
  ew_dirs=". $(workspace_members "$wt" | tr '\n' ' ')"
  ew_ok=1
  for ew_d in $ew_dirs; do
    ew_nm="$wt/$ew_d/node_modules"
    if is_link "$ew_nm"; then
      [ "$ew_hash" = "$ew_main" ] && continue
      unlink_dir "$ew_nm" || { echo "  could not remove the link at $ew_nm; the type-check may read stale packages"; echo "$ew_nm: the link to the main checkout's packages could not be removed" >> "$flaky_dir/modules.stale"; }
    fi
  done
  if [ -d "$wt/node_modules" ] && ! is_link "$wt/node_modules"; then
    [ "$(cat "$wt/node_modules/.queue-lock-hash" 2>/dev/null)" = "$ew_hash" ] && return 0
    ew_ok=0
  fi
  if [ "$ew_ok" = 1 ] && [ "$ew_hash" = "$ew_main" ] && [ -d "$main_dir/node_modules" ]; then
    for ew_d in $ew_dirs; do
      [ -d "$main_dir/$ew_d/node_modules" ] || continue
      [ -e "$wt/$ew_d/node_modules" ] && continue
      link_dir "$main_dir/$ew_d/node_modules" "$wt/$ew_d/node_modules" || echo "  could not link $wt/$ew_d/node_modules; the type-check may not find its packages"
    done
    return 0
  fi
  ew_cmd=${QUEUE_INSTALL_COMMAND:-$(workspace_install_command "$wt" "$1")}
  QUEUE_INSTALL_COMMAND=$ew_cmd install_here "$wt" "$ew_hash"
}
ensure_modules() {
  em_kind=$(workspace_kind "$wt")
  if [ -n "$em_kind" ]; then rm -f "$flaky_dir/modules.stale" 2>/dev/null; ensure_workspace "$em_kind"; return 0; fi
  rm -f "$flaky_dir/modules.stale" 2>/dev/null
  git -C "$wt" ls-files -- package.json '*/package.json' 2>/dev/null | sed 's#/package\.json$##; s#^package\.json$#.#' | while IFS= read -r d; do
    em_nm="$wt/$d/node_modules"
    em_lock=$(pkg_hash "$wt" "$d")
    em_main=$(pkg_hash "$main_dir" "$d")
    if is_link "$em_nm"; then
      if [ "$em_lock" = "$em_main" ]; then continue; fi
      unlink_dir "$em_nm" || { echo "  could not remove the link at $em_nm; the type-check may read stale packages"; echo "$em_nm: the link to the main checkout's packages could not be removed" >> "$flaky_dir/modules.stale"; continue; }
    elif [ -d "$em_nm" ]; then
      if [ "$(cat "$em_nm/.queue-lock-hash" 2>/dev/null)" = "$em_lock" ]; then continue; fi
      [ -f "$wt/$d/package-lock.json" ] || continue
      install_here "$wt/$d" "$em_lock"; continue
    fi
    mkdir -p "$wt/$d"
    if [ "$em_lock" = "$em_main" ] && [ -d "$main_dir/$d/node_modules" ]; then
      link_dir "$main_dir/$d/node_modules" "$em_nm" || echo "  could not link $em_nm; the type-check may not find its packages"
    elif [ -f "$wt/$d/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
      install_here "$wt/$d" "$em_lock"
    fi
  done
}
ensure_modules
echo "batch branch $branch in $wt from origin/$base"

# The base is checked before anything is merged. A red base (packages not
# installed, generated types stale) made every pull request look red
# after its merge, and all of them were dropped for a fault none of them
# had. Nothing is dropped for that; the batch stops and says what is red.
if [ -n "$typecheck" ] && ! typecheck_ok "$(git -C "$wt" ls-files)" "$wt"; then
  tc_first=$(grep -v '^[[:space:]]*$' "$flaky_dir/typecheck.err" 2>/dev/null | head -n 1 | tr -d '\r')
  case "$tc_first" in
    *"not the tsc command"*|*"Cannot find module"*|*"ENOENT"*|*"command not found"*)
      echo "The type-check could not run in $wt (packages are not installed there: $tc_first). That is not a red base." ;;
    *)
      if [ -s "$flaky_dir/modules.stale" ]; then
        echo "The checkout's installed packages are older than origin/$base ($(paste -sd';' "$flaky_dir/modules.stale")), so this type error is the checkout's, not main's: $tc_first"
      else
        echo "origin/$base is red here before any merge: $tc_first"
      fi ;;
  esac
  echo "Nothing was dropped for it. Fix the checkout at $wt (install the packages, regenerate the types) and run the batch again."
  exit 1
fi

carried=""
refs=""
dropped=""
good=$(git -C "$wt" rev-parse HEAD)

# Which pull requests go in. The earliest always does; of the rest, the
# largest set that conflicts with nothing already in, read pair by pair
# with git merge-tree, which merges in memory and touches no files. A
# pull request left out conflicts with one that lands now, so it will
# conflict with main: its owner is told now, with the files.
for pr in $prs; do fetch_pr_head "$pr" "$wt" >/dev/null || true; done
# The owner console reads this line to show which pull requests are being
# test-merged; it is cleared when the pairing ends.
printf 'checking %s\n' "$(printf '%s ' $prs | sed 's/ $//')" > "$flaky_dir/now" 2>/dev/null || true
pairs=""
for a in $prs; do for b in $prs; do
  [ "$a" -lt "$b" ] || continue
  if ! git -C "$wt" merge-tree --write-tree "refs/queue/pr-$a" "refs/queue/pr-$b" >/dev/null 2>&1; then
    # a pair that clashes only in generated files is resolved on the batch
    pf=$(git -C "$wt" merge-tree --write-tree --name-only "refs/queue/pr-$a" "refs/queue/pr-$b" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    if [ "$(generated_only "$pf" "$gen_cfg")" != yes ]; then pairs="$pairs
$a $b"; fi
  fi
done; done
: > "$flaky_dir/now" 2>/dev/null || true
: > "$flaky_dir/clashes" 2>/dev/null || true
if [ -n "$pairs" ]; then
  group=$(anchored_group "$(printf '%s ' $prs)" "$pairs" | tr '\n' ' ')
  for pr in $prs; do
    case " $group " in *" $pr "*) continue ;; esac
    with=$(printf '%s\n' "$pairs" | awk -v p="$pr" -v g=" $group " '$1 == p && index(g, " " $2 " ") { print $2; exit } $2 == p && index(g, " " $1 " ") { print $1; exit }')
    files=$(git -C "$wt" merge-tree --write-tree --name-only "refs/queue/pr-$pr" "refs/queue/pr-$with" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    batch_line "$pr" "left for later" "conflicts with #$with, which goes in this batch"
    printf '%s %s\n' "$pr" "$with" >> "$flaky_dir/clashes" 2>/dev/null || true
    notify_conflict "$pr" "$files" "$with"
  done
  prs=$group
fi
# The console shows the batch being built here, which takes minutes a
# pull request on a slow machine and once looked like a stalled queue:
# "building MERGED TOTAL CURRENT MEMBER...", cleared when the loop ends.
b_total=$(printf '%s\n' $prs | grep -c .)
b_merged=0
for pr in $prs; do
  printf 'building %s %s %s %s\n' "$b_merged" "$b_total" "$pr" "$(printf '%s ' $prs | sed 's/ $//')" > "$flaky_dir/now" 2>/dev/null || true
  hw=$(pr_held "$pr")
  if [ -n "$hw" ]; then batch_line "$pr" "left out" "$hw"; continue; fi
  # Read fresh, not from the cache: a pull request merged or closed since
  # the list was made has nothing left to merge.
  pst=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '"\(.state) \(.merged)"' 2>/dev/null || true)
  case "$pst" in
    "closed true") batch_line "$pr" "skipped" "already merged"; continue ;;
    closed*) batch_line "$pr" "skipped" "closed"; continue ;;
  esac
  why=$(folder_blocks "$pr"); [ -n "$why" ] || why=$(migration_blocks "$pr")
  if [ -n "$why" ]; then batch_line "$pr" "refused" "$why"; continue; fi
  # Merge the head the pull request reports: from its pull ref, or from
  # its branch when GitHub's pull ref lags behind.
  head=$(fetch_pr_head "$pr" "$wt") || { batch_line "$pr" "left for later" "$fph_why"; continue; }
  title=$(pr_field "$pr" 3); [ -n "$title" ] || title="PR $pr"
  if ! git -C "$wt" merge -q --no-ff --no-edit -m "Merge PR #$pr into $branch: $title" "$head" >/dev/null 2>&1; then
    git -C "$wt" merge --abort >/dev/null 2>&1 || true
    git -C "$wt" reset -q --hard "$good"
    cfl=$(git -C "$wt" merge-tree --write-tree --name-only "$good" "$head" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    gen_note=""; if [ "$(generated_only "$cfl" "$gen_cfg")" = yes ]; then gen_note=generated; fi
    # Generated files only (scripts/ci/generated-paths.txt): take either
    # side, rebuild them here, and let the batch's one full run prove it.
    # Six green pull requests once landed one at a time for a package each
    # had rebuilt: an hour of landings for twenty minutes of work.
    if [ "$gen_note" = generated ] && git -C "$wt" merge -q --no-ff --no-edit -X theirs -m "Merge PR #$pr into $branch: $title" "$head" >/dev/null 2>&1; then
      rb=$(rebuild_command "$gen_cfg")
      if [ -n "$rb" ]; then
        if (cd "$wt" && sh -c "$rb") >/dev/null 2>"$flaky_dir/rebuild.err"; then
          git -C "$wt" add -A >/dev/null 2>&1 || true
          git -C "$wt" commit -q --amend --no-edit >/dev/null 2>&1 || true
          echo "  #$pr conflicted only in generated files; took either side and rebuilt them ($rb)."
        else
          git -C "$wt" reset -q --hard "$good"
          batch_line "$pr" "dropped" "conflicted only in generated files, but the rebuild failed: $(tail -n 1 "$flaky_dir/rebuild.err" 2>/dev/null | tr -d '\r')"
          dropped="$dropped $pr"
          continue
        fi
      else
        echo "  #$pr conflicted only in generated files; took either side. No rebuild: line in scripts/ci/generated-paths.txt, so the batch's full run must prove them."
      fi
    else
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      git -C "$wt" reset -q --hard "$good"
      if [ "$gen_note" = generated ]; then
        batch_line "$pr" "dropped" "conflicts with the batch so far; generated only: a rebuild on the batch would resolve this"
      else
        batch_line "$pr" "dropped" "conflicts with the batch so far"
      fi
      notify_conflict "$pr" "$cfl" main "$gen_note"
      dropped="$dropped $pr"
      continue
    fi
  fi
  changed=$(git -C "$wt" diff --name-only "origin/$base...$head")
  # a member that changes dependencies gets them installed before its check
  case "
$changed" in *"
package-lock.json"*|*"/package-lock.json"*|*"pnpm-lock.yaml"*|*"yarn.lock"*|*"
package.json"*|*"/package.json"*) ensure_modules ;; esac
  if [ -n "$typecheck" ] && ! typecheck_ok "$changed" "$wt"; then
    git -C "$wt" reset -q --hard "$good"
    batch_line "$pr" "dropped" "the type-check went red after merging it: $(head -n 1 "$flaky_dir/typecheck.err" 2>/dev/null | tr -d '\r')"
    dropped="$dropped $pr"
    continue
  fi
  red=""; not_run=""
  for f in $(tests_for_diff "$changed"); do
    [ -f "$wt/$f" ] || continue
    rc=0; (cd "$wt" && $test_one "$f") >/dev/null 2>"$flaky_dir/test.err" || rc=$?
    if [ "$rc" -eq 3 ]; then
      # Its runner could not be told: not run here, never red.
      not_run="$not_run $f"
      continue
    fi
    if [ "$rc" -eq 2 ]; then
      # The runner could not start. That is not a red test, and dropping
      # every pull request for it would empty the batch for nothing.
      echo "The test runner could not run $f: $(tail -n 3 "$flaky_dir/test.err" 2>/dev/null | tr '\r\n' '  ')"
      echo "Nothing was dropped for it. Fix the runner, or set QUEUE_TEST_COMMAND to the project's one-file test command, and run the batch again."
      git -C "$wt" reset -q --hard "$good"
      exit 1
    fi
    if [ "$rc" -ne 0 ]; then
      red=$f
      [ -s "$flaky_dir/test.err" ] && echo "  $(tail -n 3 "$flaky_dir/test.err" | tr '\r\n' '  ')"
      break
    fi
  done
  if [ -n "$red" ]; then
    git -C "$wt" reset -q --hard "$good"
    batch_line "$pr" "dropped" "$red went red after merging it"
    dropped="$dropped $pr"
    continue
  fi
  [ -z "$not_run" ] || batch_line "$pr" "kept" "not run here:$not_run (its test runner could not be told; the batch's full run covers it)"
  # Cancel the PR's own CI run; the batch's one run covers it.
  # Queued runs too: a queued member run still takes a runner the moment
  # one frees, ahead of the batch. A run that ignores the cancel (jobs
  # already picked up) is force-cancelled.
  gh run list --branch "$(pr_field "$pr" 1)" --json databaseId,status -q '.[] | select(.status != "completed") | .databaseId' 2>/dev/null \
    | while read -r id; do
      [ -n "$id" ] || continue
      gh run cancel "$id" >/dev/null 2>&1 || true
      sleep 5
      [ "$(gh api "repos/{owner}/{repo}/actions/runs/$id" --jq .status 2>/dev/null)" = completed ] || gh api -X POST "repos/{owner}/{repo}/actions/runs/$id/force-cancel" >/dev/null 2>&1 || true
    done
  good=$(git -C "$wt" rev-parse HEAD)
  carried="$carried$pr	$title
"
  refs="$refs$(carried_refs "$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '.body // ""' 2>/dev/null)" "$pr")
"
  batch_line "$pr" "merged into the batch"
  b_merged=$((b_merged + 1))
done
: > "$flaky_dir/now" 2>/dev/null || true

# One member is not a batch: GitHub refused a one-member batch pull request
# because its required check had not run yet, and the member's own green
# run already proves it. Merge it serially instead.
if [ -n "$carried" ] && [ "$(printf '%s\n' "$carried" | grep -c .)" -eq 1 ]; then
  only=$(printf '%s' "$carried" | cut -f1)
  echo "Only #$only survived the batch; merging it serially instead of opening a batch of one."
  because="batch of one"
  serial_one "$only"
  for pr in $dropped; do serial_one "$pr"; done
  exit 0
fi

if [ -z "$carried" ]; then
  echo "Nothing survived the batch; running the serial queue for all of them."
  because="dropped from batch"
  for pr in $dropped; do serial_one "$pr"; done
  exit 0
fi

if [ -f "$wt/status/build.sh" ]; then
  (cd "$wt" && sh status/build.sh) >/dev/null
  if ! git -C "$wt" diff --quiet -- STATUS.md; then
    git -C "$wt" add STATUS.md && git -C "$wt" commit -q -m "Rebuild the status page for $branch"
  fi
fi

# An earlier batch pull request still open is superseded by this one; close
# it with a comment rather than leave it next to the new one.
close_pr() { # NUMBER REASON
  gh api -X POST "repos/{owner}/{repo}/issues/$1/comments" -f body="$2" >/dev/null 2>&1 || true
  gh api -X PATCH "repos/{owner}/{repo}/pulls/$1" -f state=closed >/dev/null 2>&1 && echo "closed batch PR #$1: $2"
}
gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select((.body // "") | (contains("<!-- merge-queue:batch -->") or startswith("One integration run for the pull requests below"))) | .number' 2>/dev/null \
  | while read -r old; do if [ -n "$old" ]; then close_pr "$old" "Superseded by a new batch from the queue; its members are carried there if still green."; fi; done

git -C "$wt" push -q -u origin "$branch"
body=$(batch_pr_body "$carried" "$refs")
batch_pr=$(gh api -X POST "repos/{owner}/{repo}/pulls" -f base="$base" -f head="$branch" -f title="Batch $day: $(printf '%s' "$carried" | wc -l | tr -d ' ') pull requests" -f body="$body" --jq .number 2>"$gh_err") || { rate_stop; echo "Could not open the batch pull request: $(head -n 1 "$gh_err" 2>/dev/null). The branch $branch is pushed; open it by hand or run the batch again."; exit 1; }
echo "batch PR #$batch_pr opened; waiting for the one full CI run"
batch_sha=$(git -C "$wt" rev-parse HEAD)
batch_ok=no
if wait_for_run "$batch_pr" "$branch" && wait_required "$batch_sha"; then batch_ok=yes
else
  # A job cancelled before a runner took it fails the required check
  # without anything being wrong: re-run the failed and cancelled jobs once
  # and wait again, rather than close a good batch.
  checks=$(gh api "repos/{owner}/{repo}/commits/$batch_sha/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)"' 2>/dev/null)
  if [ "$(rest_rollup_named "$checks" "${QUEUE_SUMMARY_CHECK:-CI passed}")" = cancelled ]; then
    run=$(latest_run "$branch"); run_id=${run%%	*}
    if [ -n "$run_id" ] && gh run rerun "$run_id" --failed >/dev/null 2>&1; then
      echo "A job on the batch was cancelled before it ran; re-ran the failed and cancelled jobs and waiting again."
      sleep 30
      wait_for_run "$batch_pr" "$branch" && wait_required "$batch_sha" && batch_ok=yes
    fi
  fi
fi
if [ "$batch_ok" != yes ]; then
  close_pr "$batch_pr" "The batch's CI was not green, so nothing merged; closed so the next batch starts clean. The member pull requests are untouched."
  echo "The batch run is not green; nothing merged. Fix it on $branch or drop a PR and run again."
  exit 1
fi
wait_quiet_main
merged_sha=$(gh api -X PUT "repos/{owner}/{repo}/pulls/$batch_pr/merge" -f merge_method=merge --jq .sha 2>"$gh_err") || { rate_stop; echo "GitHub refused the batch merge: $(head -n 1 "$gh_err" 2>/dev/null). Nothing merged; run the batch again."; exit 1; }
echo "batch PR #$batch_pr merged into $base with a merge commit"
# GitHub can show a carried pull request as "closed, not merged", which
# reads as abandoned. Say on each where it went.
for pr in $(printf '%s' "$carried" | cut -f1); do
  gh api -X POST "repos/{owner}/{repo}/issues/$pr/comments" -f body="Merged into $base in batch #$batch_pr (commit ${merged_sha:-unknown}), with its history kept. GitHub may show this pull request as closed rather than merged; its changes are on $base." >/dev/null 2>&1 || true
  echo "#$pr merged via batch #$batch_pr"
done
for pr in $(printf '%s' "$carried" | cut -f1); do
  tidy_worktree "$(pr_field "$pr" 1)"
done

if [ -n "$dropped" ]; then
  echo "serial queue for the dropped PRs:$dropped"
  because="dropped from batch"
  for pr in $dropped; do serial_one "$pr"; done
fi
if [ -z "$QUEUE_IN_DRAIN" ]; then deploy_if_due "$b_begin"; fi
