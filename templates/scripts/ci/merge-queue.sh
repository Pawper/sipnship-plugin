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
  mkdir -p "$qc/ci/queue" && { for f in "$here"/* "$here"/queue/*; do if [ -f "$f" ]; then case "$f" in "$here"/queue/*) cp "$f" "$qc/ci/queue/" 2>/dev/null || true ;; *) cp "$f" "$qc/ci/" 2>/dev/null || true ;; esac; fi; done; }
  for f in worktrees.sh worktrees-lib.sh; do if [ -f "$here/../$f" ]; then cp "$here/../$f" "$qc/"; fi; done
  QUEUE_FROM_COPY=1; export QUEUE_FROM_COPY
  exec sh "$qc/ci/merge-queue.sh" "$@"
fi
. "$here/lib.sh"
. "$here/batch-lib.sh"
. "$here/numbering-lib.sh"
# One library a step, in this order; each holds functions only. Read from the
# queue's own folder, which is beside this script wherever it runs from.
. "$here/queue/state.sh"
. "$here/queue/requests.sh"
. "$here/queue/rush.sh"
. "$here/queue/runs.sh"
. "$here/queue/choose.sh"
. "$here/queue/rerun.sh"
. "$here/queue/serial.sh"
. "$here/queue/batch.sh"
. "$here/queue/deploy.sh"
. "$here/queue/attention.sh"
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
. "$here/gate-lib.sh"
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
# One queue at a time. A queue takes .scratch/queue/lock and a second one
# is refused with a line naming the first, so agents do not start parallel
# waits that spend the same budget twice. The batch or serial run a drain
# starts itself is inside the drain's lock. A lock whose process is gone,
# or older than three hours, is a crash's leftover and is taken over.
lock_file=$flaky_dir/lock
have_lock=no
queue_step="starting"
# Drain: merge everything that is green, round after round, so nobody
# writes their own loop. Each round reads every open pull request in one
# call, merges the green ones (as a batch whenever two or more are green), and waits
# for the running ones. It stops when nothing is green and nothing is
# running, when nothing new turned green, after --rounds rounds (default
# six), or after QUEUE_DRAIN_MINUTES (default ninety).
take_lock
if [ "$mode" = drain ]; then
  rounds=${rounds:-6}
  drain_minutes=${QUEUE_DRAIN_MINUTES:-90}
  # A drain started in a session says so, so the scheduled drain skips
  # instead of racing it. The window is QUEUE_DRAIN_MINUTES (default 25),
  # renewed each round and cleared by the exit trap however the drain
  # ends: a drain that died once held the backstop off for ten hours.
  window_minutes=${QUEUE_DRAIN_MINUTES:-25}
  renew_window() {
    [ -n "${local_drain_mark:-}" ] || return 0
    set_repo_var QUEUE_LOCAL_DRAIN_UNTIL "$(drain_window_until "$(date +%s)" "$window_minutes")" >/dev/null 2>&1 || true
  }
  if [ -z "${GITHUB_ACTIONS:-}" ]; then local_drain_mark=yes; renew_window; fi
  : > "$flaky_dir/stopped" 2>/dev/null || true; runner_labels_keep # one runner kept for the batch and main
  stop_why=""
  d_start=$(date +%s); round=0; tried=""; retried=""; attention=""; last_look=""; cancel_heads=""
  d_begin=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
  while [ "$round" -lt "$rounds" ]; do
    round=$((round + 1))
    renew_window
    queue_step="drain round $round: reading the open pull requests"
    rate_guard
    # Requests to the queue, at every tick: this round's start, which each
    # two-minute hold also comes back to. A "land this next" left waiting
    # behind a batch lands here first, ahead of any other green one.
    queue_step="drain round $round: reading requests"
    requests_tick drain
    queue_step="drain round $round: reading the open pull requests"
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
        gh_write api -X POST "repos/{owner}/{repo}/issues/$bp/comments" -f body="Closed by the queue: member(s)$landed landed on their own, so this batch no longer matches main. The rest are queued again on their own." >/dev/null 2>&1 || true
        gh_write api -X PATCH "repos/{owner}/{repo}/pulls/$bp" -f state=closed >/dev/null 2>&1 && say "round $round: closed batch #$bp, since$landed landed on their own."
        settled="$settled $bp $(printf '%s' "$landed" | tr -d '#')"
      elif [ "$bstate" = passed ] && bsha=$(gh_write api -X PUT "repos/{owner}/{repo}/pulls/$bp/merge" -f merge_method=merge --jq .sha 2>/dev/null); then
        say "round $round: merged batch #$bp, left green by an earlier run (members:$(printf ' #%s' $bm))."; ci_dispatch "$base"
        settled="$settled $bp $bm"
        for m in $bm; do gh_write api -X POST "repos/{owner}/{repo}/issues/$m/comments" -f body="Merged into $base in batch #$bp (commit $bsha), with its history kept. GitHub may show this pull request as closed rather than merged; its changes are on $base." >/dev/null 2>&1 || true; done
      elif [ "$bstate" = failed ]; then
        gh_write api -X POST "repos/{owner}/{repo}/issues/$bp/comments" -f body="Closed by the queue: left open by an earlier run with its required check failed. Its members are queued again on their own." >/dev/null 2>&1 || true
        gh_write api -X PATCH "repos/{owner}/{repo}/pulls/$bp" -f state=closed >/dev/null 2>&1 && say "round $round: closed batch #$bp, whose required check failed; its members are queued again."
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
    # While a rush list stands, the others are paused: only the rush ones
    # are read, and only the first of them is merged by the round.
    mkdir -p "$flaky_dir" 2>/dev/null || true
    rush_now=$(tr -d '\r' < "$flaky_dir/rush.list" 2>/dev/null | tr '\n' ' ')
    if [ -n "$(printf '%s' "$rush_now" | tr -d ' ')" ]; then
      open=$(printf '%s\n' "$open" | awk -F'\t' -v k=" $rush_now " 'NF && index(k, " " $1 " ")')
      [ "$rush_now" = "${last_rush:-}" ] || say "round $round: a rush change is landing ($(printf '#%s ' $rush_now)); the others are paused until it has."
      last_rush=$rush_now
    fi
    queue_step="drain round $round: re-running failed jobs"
    # A red pull request gets one retry of its failed jobs; a second red,
    # or a conflict, is collected and named when the drain ends.
    for r in $(drain_retry "$open" "$base" "$retried"); do
      drain_rerun_one "$r"
      retried="$retried $r"
    done
    attention=$(printf '%s
%s
' "$attention" "$(drain_attention "$open" "$base" "$retried")" | sed '/^$/d' | sort -u -n)
    printf '%s\n' "$open" > "$flaky_dir/open.tsv" 2>/dev/null || true
    printf '%s\n' "$attention" | sed '/^$/d' | awk -F'\t' '{ w = ($2 != "" ? $2 : "failed CI twice"); printf "%s\t%s\t%s\t\n", $1, w, (w ~ /cancelled/ ? "every job was cancelled again" : "its checks stay red") }' > "$flaky_dir/attention.tsv" 2>/dev/null || true
    publish_now draining "$flaky_dir/open.tsv"
    queue_step="drain round $round: choosing what to merge"
    pick=$(drain_candidates "$open" "$base" "$tried")
    if [ -n "$(printf '%s' "$rush_now" | tr -d ' ')" ]; then pick=$(printf '%s\n' "$pick" | grep -x "$(printf '%s' "$rush_now" | awk '{print $1}')"); fi
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
    say_round_pick "$round" "$n" "$pick"
    QUEUE_IN_DRAIN=1; export QUEUE_IN_DRAIN
    : > "$flaky_dir/untried" 2>/dev/null || true
    : > "$flaky_dir/batch.why" 2>/dev/null || true
    if [ "$n" -ge 2 ]; then sh "$0" --batch --base "$base" $pick 2>&1 | tee -a "$log_file" || true; else sh "$0" --serial --base "$base" $pick 2>&1 | tee -a "$log_file" || true; fi
    # A pull request the round could not even try (main would not fetch)
    # is not tried: it stays in for the next round.
    untried=$(tr -d '\r' < "$flaky_dir/untried" 2>/dev/null | tr '\n' ' ')
    for t in $pick; do
      case " $untried " in *" $t "*) ;; *) tried="$tried $t" ;; esac
    done
    if [ -n "$(printf '%s' "$untried" | tr -d ' ')" ]; then say "round $round: main could not be fetched; trying$(printf ' #%s' $untried) again next round."; fi
    # A batch that could not even be built leaves its reason; the green
    # pull requests it held are still green, so the drain says why it
    # stopped rather than look quiet.
    b_why=$(head -n 1 "$flaky_dir/batch.why" 2>/dev/null | tr -d '\r')
    [ -z "$b_why" ] || stop_why=$b_why
    if [ $(( $(date +%s) - d_start )) -ge $((drain_minutes * 60)) ]; then
      say "Drained for $drain_minutes minutes; stopping. Run --drain again to go on."
      break
    fi
  done
  if [ -n "$stop_why" ]; then
    stop_line=$(drain_stop_line "$(date '+%-I:%M %p' 2>/dev/null || date '+%H:%M')" "$stop_why")
    say "$stop_line"
    printf '%s\n' "$stop_line" > "$flaky_dir/stopped" 2>/dev/null || true
  fi
  say "drain rounds done"
  deploy_if_due "$d_begin"
  # One stuck pull request a drain's end, never two: merge main into one
  # that fell behind or clashes but merges cleanly, ask a real clash's
  # agent once, or start CI again once on one red outside its code.
  # First the steps agents held until another pull request landed: merge
  # main in where that was the step, or name the waiting session. A merge
  # here is this drain's end's one re-merge, so nothing is unstuck after it.
  queue_step="taking held steps"
  held_steps
  queue_step="unsticking one pull request"
  [ "$held_merged" = yes ] || unstick_one
  # Re-read each one before calling it a failure: a pull request red
  # earlier in the drain may be green, or only cancelled, by now.
  still=""
  [ -z "$attention" ] || still=$(attention_recheck "$attention")
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

if [ "$mode" = serial ]; then queue_serial; fi

queue_batch
