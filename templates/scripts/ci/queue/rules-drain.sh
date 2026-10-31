#!/bin/sh
# Pure helpers for the drain: what to merge, re-run and wait for, the REST
# rollups, the rate limit and the lock. Loaded by scripts/ci/batch-lib.sh.

# drain_candidates LIST BASE [TRIED]
# LIST is one open pull request per line:
#   "NUMBER<TAB>DRAFT(true|false)<TAB>MERGEABLE<TAB>ROLLUP<TAB>BASE_BRANCH"
# where ROLLUP is green, red, pending or none. Print, one per line in
# number order, the pull requests the drain should merge this round: not a
# draft, aimed at BASE, not conflicting, green, and not in TRIED (numbers a
# previous round already tried and could not merge).
drain_candidates() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && toupper($3) != "CONFLICTING" && $4 == "green" && index(tried, " " $1 " ") == 0 { print $1 }' | sort -n
}

# drain_waiting LIST BASE
# How many non-draft pull requests aimed at BASE are still running CI.
drain_waiting() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && ($4 == "pending" || $4 == "cancelled") { n++ } END { print n + 0 }'
}

# drain_retry LIST BASE RETRIED
# The red pull requests (not drafts, aimed at BASE) whose failed run has
# not been re-run yet in this drain: one retry each, because a flaky test
# or a lost runner should not stop a change.
drain_retry() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && (($4 == "red" && index(tried, " " $1 " ") == 0) || $4 == "cancelled") { print $1 }' | sort -n
}

# rerun_choice RUNS HEAD CANCEL_HEADS: which CI run the drain may re-run.
# RUNS is one run per line, newest first, "id<TAB>head sha<TAB>status<TAB>
# conclusion", every run of the pull request's branch. CI cancels within a
# pull request's concurrency group, so re-running an old run cancels the
# fresh one: two pull requests once went red with every job cancelled.
# Prints "wait" while any run is queued or in progress; "twice" when the
# newest run on HEAD was cancelled and that head already had its re-run
# (a head in CANCEL_HEADS); "rerun ID" for the newest completed run on
# HEAD; nothing when HEAD has no run.
rerun_choice() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v head="$2" -v done=" $3 " '
    NF >= 3 && $3 != "completed" { busy = 1 }
    NF >= 3 && $2 == head && pick == "" { pick = $1; conc = $4 }
    END {
      if (busy) { print "wait"; exit }
      if (pick == "") exit
      if (conc == "cancelled" && index(done, " " head " ") > 0) { print "twice"; exit }
      print "rerun " pick
    }'
}

# drain_attention LIST BASE RETRIED
# The pull requests a person or an agent must look at, one per line as
# "NUMBER<TAB>why": conflicting with the base, or red again after its one
# retry. The drain exits non-zero naming these, so nobody has to notice.
drain_attention() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base {
      if (toupper($3) == "CONFLICTING") printf "%s\thas conflicts with %s\n", $1, base
      else if ($4 == "red" && index(tried, " " $1 " ") > 0) printf "%s\tfailed CI twice\n", $1

    }' | sort -n
}

# rest_rollup WORDS
# WORDS is one check-run outcome per line as REST reports it: a conclusion
# (success, failure, neutral, cancelled, timed_out, action_required,
# skipped, stale) or, while the run is not complete, its status (queued,
# in_progress, waiting, pending). Print the one word the drain reads:
# none, red, pending, cancelled or green. A cancelled job is not a red one:
# a runner hiccup or a newer push cancels it, and the drain re-runs it
# once rather than calling the change broken.
rest_rollup() {
  printf '%s\n' "$1" | tr -d '\r' | tr 'A-Z' 'a-z' | awk '
    NF == 0 { next }
    { n++ }
    /failure|timed_out|action_required|startup_failure/ { red = 1 }
    /cancelled/ { canc = 1 }
    /queued|in_progress|waiting|pending|requested/ { pend = 1 }
    END { if (n == 0) print "none"; else if (red) print "red"; else if (pend) print "pending"; else if (canc) print "cancelled"; else print "green" }'
}

# required_check LINES [NAME]
# LINES is "name<TAB>status<TAB>conclusion" per check run on one commit.
# Print the state of the check branch protection requires (NAME, default
# "CI passed") on that commit: passed, failed, pending, or missing when it
# has not reported. GitHub refuses a merge until it has passed on the head
# commit, whatever else is green: "Required status check CI passed is
# expected" stopped batches three times while the queue watched the
# workflow run instead of the check.
required_check() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v want="${2:-CI passed}" '
    $1 == want { found = 1; st = tolower($2); c = tolower($3)
      if (st != "completed") state = "pending"
      else if (c == "success" || c == "neutral" || c == "skipped") state = "passed"
      else state = "failed" }
    END { print found ? state : "missing" }'
}

# job_outcome CONCLUSION STEP_CONCLUSIONS
# A pull-request job whose own step failed cancels the rest of its run, and
# GitHub then shows that job as cancelled too. Read it as the failure it
# is: a cancelled job with a failed step is "failure", so the run gets the
# one retry a failure gets, never the every-round re-run of a cancellation.
job_outcome() {
  case "$1" in
    cancelled|canceled) case " $2 " in *" failure "*) echo failure; return ;; esac ;;
  esac
  echo "$1"
}

# rest_rollup_named LINES [SUMMARY]
# LINES is "name<TAB>outcome" per check run. The summary check (SUMMARY,
# default "CI passed") fails whenever a job it waits on was cancelled, so a
# job cancelled before any runner took it read as a red pull request and
# was set aside as "failed CI twice". When another check was cancelled, the
# summary's failure is left out, and the rollup is cancelled, which the
# drain re-runs and waits on.
rest_rollup_named() {
  rrn=$(printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v sum="${2:-CI passed}" '
    NF >= 2 { name[NR] = $1; out[NR] = tolower($2); if (out[NR] ~ /cancelled/ && $1 != sum) canc = 1; n = NR }
    END { for (i = 1; i <= n; i++) { if (canc && name[i] == sum && out[i] ~ /failure/) continue; print out[i] } }')
  rest_rollup "$rrn"
}

# mergeable_word STATE
# STATE is REST's mergeable_state: clean, unstable, has_hooks, behind,
# blocked, dirty, draft, unknown. Print the word the drain reads:
# CONFLICTING for dirty, UNKNOWN for unknown or empty, MERGEABLE otherwise.
mergeable_word() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    dirty) echo CONFLICTING ;;
    ''|unknown) echo UNKNOWN ;;
    *) echo MERGEABLE ;;
  esac
}

# drain_hold GREEN WAITING
# Print "yes" when the drain should wait before merging: one green pull
# request would merge serially while WAITING others are still
# running CI, and a serial merge moves main under every one of them, so
# they are updated and sent back round CI and the batch that follows has
# nothing. Hold until they finish, then batch. Print "no" when nothing is
# waiting, nothing is green, or there are enough green ones to batch now.
drain_hold() {
  if [ "${1:-0}" -eq 1 ] && [ "${2:-0}" -gt 0 ]; then echo yes; else echo no; fi
}

# rate_wait RATE NOW [FLOOR]
# RATE is "remaining<TAB>reset_epoch" as gh api rate_limit reports it for
# the core API. Print the seconds the queue should wait before spending
# more calls: 0 when more than FLOOR (default 500) calls are left, when the
# window has already reset, or when RATE is empty (the budget could not be
# read, and the queue goes on rather than stall); otherwise the seconds
# until the reset, at least one.
rate_wait() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v floor="${3:-500}" '
    NR == 1 {
      rem = $1 + 0; reset = $2 + 0
      if ($1 == "" || rem > floor || reset <= now) { print 0; exit }
      w = reset - now; if (w < 1) w = 1; print w; exit
    }
    END { if (NR == 0) print 0 }'
}

# rate_limit_hit TEXT
# Print "yes" when TEXT, the error output of a gh call, says GitHub's API
# rate limit was exceeded, "no" otherwise.
rate_limit_hit() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    *"rate limit exceeded"*|*"api rate limit"*|*"secondary rate limit"*) echo yes ;;
    *) echo no ;;
  esac
}

# queue_lock_reason LOCK NOW ALIVE [STALE_SECONDS]
# LOCK is the text of the queue's lock file: "pid<TAB>started_epoch<TAB>mode".
# ALIVE is yes when that pid is still running. Print why a second queue must
# not start ("a --drain started 12 minutes ago is still running (pid 4242)"),
# or nothing when LOCK is empty, its process is gone, or it is older than
# STALE_SECONDS (default three hours), which is a lock a crash left behind.
queue_lock_reason() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v alive="$3" -v stale="${4:-10800}" '
    NR == 1 && NF >= 3 && $1 != "" {
      age = now - ($2 + 0)
      if (alive != "yes" || age > stale) exit
      printf "a %s started %d minute(s) ago is still running (pid %s)\n", $3, int(age / 60), $1
      exit
    }'
}

