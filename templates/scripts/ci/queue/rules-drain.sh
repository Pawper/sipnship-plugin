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
  if [ "${2:-0}" -gt 0 ] && { [ "${1:-0}" -eq 1 ] || { [ "${1:-0}" -gt 1 ] && [ "${round_hold:-}" = yes ]; }; }; then echo yes; else echo no; fi
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

# remote_drain_reason RUNS NOW
# RUNS is one line per Queue drain run on GitHub that is in progress or
# queued: "id<TAB>status<TAB>created_epoch". Print why a local queue must not
# start ("the Queue drain on GitHub started 12 minute(s) ago is still running
# (run 123)", "queued" for a run not yet started), or nothing for no runs.
remote_drain_reason() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" '
    NR == 1 && NF >= 3 && $1 != "" {
      age = now - ($3 + 0)
      if (age < 0) age = 0
      st = ($2 == "queued") ? "queued" : "still running"
      printf "the Queue drain on GitHub started %d minute(s) ago is %s (run %s)\n", int(age / 60), st, $1
      exit
    }'
}

# Unsticking, at a drain's end (scripts/ci/QUEUE.md, "Unsticking"). A pull
# request that fell behind main, clashed with it, or went red for a cause
# outside its code once sat until a person noticed: three in one evening,
# one red twice from an install collision, one whose CI never started.

# unstick_candidates LIST BASE
# LIST is the drain's rows, "NUMBER<TAB>DRAFT<TAB>MERGEABLE<TAB>ROLLUP<TAB>
# BASE_BRANCH". Print, in number order, the pull requests the drain's end
# may unstick: not a draft, aimed at BASE, and conflicting, or with checks
# red, cancelled or none at all. Green and running ones are not stuck.
unstick_candidates() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" '
    NF >= 5 && $2 == "false" && $5 == base && (toupper($3) == "CONFLICTING" || $4 == "red" || $4 == "cancelled" || $4 == "none") { print $1 }' | sort -n
}

# unstick_busy LIST BASE
# "yes" when a pull request aimed at BASE is still running CI, "no"
# otherwise. While one runs, the drain's end starts no CI of its own, so
# two re-merges never run at once; it may still comment on a clash.
unstick_busy() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" '
    NF >= 5 && $2 == "false" && $5 == base && $4 == "pending" { b = 1 } END { print b ? "yes" : "no" }'
}

# unstick_mark KIND SHA: the hidden line the queue leaves in its comment,
# so it never does the same thing twice to the same head commit.
unstick_mark() {
  printf '<!-- merge-queue:unstick %s %s -->\n' "$1" "$2"
}

# unstick_marks COMMENTS
# COMMENTS is a pull request's comment bodies. Print "KIND SHA" for each
# mark unstick_mark left in them, one per line.
unstick_marks() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/.*<!-- merge-queue:unstick \([a-z]*\) \([0-9a-fA-F]*\) -->.*/\1 \2/p'
}

# outside_cause JOBS [SUMMARY]
# JOBS is one job of a pull request's newest CI run per line: "name<TAB>
# conclusion<TAB>the step that failed<TAB>text", where text is the job's
# annotations and the error lines of its log. Print, in a few words, the
# cause outside the code when every job that did not pass stopped for one:
# an install step that hit a Windows file lock (EPERM, EBUSY), a runner
# lost or shut down mid-run, a network error, a set-up step, or a job
# cancelled with no step of its own failed. Print nothing when any job
# failed in the code, when the lockfile is out of date (that is the
# change's own), or when no job failed. The summary job (SUMMARY, default
# "CI passed") fails whenever another does, so it is not read.
outside_cause() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v sum="${2:-CI passed}" '
    NF == 0 || $1 == sum { next }
    {
      c = tolower($2); s = tolower($3); t = tolower($4)
      if (c == "" || c == "success" || c == "skipped" || c == "neutral") next
      n++
      w = ""
      if (t ~ /outdated_lockfile|lockfile (is )?(out of date|not up to date)/) { code = 1; next }
      if ((c == "cancelled" || c == "canceled") && s == "") w = "a cancelled run"
      else if (t ~ /lost communication|shutdown signal|runner .*(went offline|was lost)|operation was canceled/) w = "a runner lost mid-run"
      else if (s ~ /install|set ?up|setup|cache/ && t ~ /eperm|ebusy/) { w = (t ~ /eperm/) ? "an install error (EPERM)" : "an install error (EBUSY)" }
      else if (t ~ /econnreset|etimedout|eai_again|socket hang up|err_pnpm_fetch|enotfound/) w = "a network error"
      else if (s ~ /^(set up job|checkout|run actions\/checkout|post )/) w = "a runner set-up step"
      if (w == "") { code = 1; next }
      if (why == "") why = w
    }
    END { if (n > 0 && !code) print why }'
}

# unstick_action ROW MARKS BUSY
# ROW is one stuck pull request's facts: "MERGEABLE<TAB>ROLLUP<TAB>HEAD<TAB>
# BEHIND<TAB>MERGES<TAB>CAUSE<TAB>RUN". MERGEABLE is the drain's word
# (CONFLICTING, MERGEABLE, UNKNOWN); ROLLUP its checks (red, cancelled,
# none, pending, green); HEAD its head commit; BEHIND how many commits main
# is ahead of it; MERGES yes when main merges into it cleanly here, no for
# a real conflict; CAUSE what outside_cause said of a red run, empty for
# the code; RUN the newest CI run on HEAD: none, busy or done. MARKS is
# unstick_marks of its comments; BUSY is unstick_busy. Print one word:
#   clash   a real conflict, not yet commented on for HEAD: ask its agent
#   update  behind main, or shown as a clash but merging cleanly: merge
#           main in through GitHub's update-branch, and CI runs by itself
#   rerun   red outside the code, cancelled, or no checks with a run to
#           re-run, not yet re-run by the drain's end for HEAD
#   cannot  no checks, no run on HEAD and up to date: nothing to re-run,
#           and a pull request's CI starts only on a push to it
# or nothing: running, green, red in its code (its agent's turn), already
# done for HEAD, or BUSY while it would start CI.
unstick_action() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v marks="$(printf '%s' "$2" | tr '\n' '|')" -v busy="$3" '
    NR == 1 {
      mw = toupper($1); roll = $2; head = $3; behind = $4 + 0; merges = $5; cause = $6; run = $7
      done = "|" marks "|"
      if (merges == "no") { if (index(done, "|clash " head "|") == 0) print "clash"; exit }
      if (busy == "yes") exit
      if (mw == "CONFLICTING") { print "update"; exit }
      if (roll == "red" && cause == "") exit
      if (roll != "red" && roll != "cancelled" && roll != "none") exit
      if (behind > 0) { print "update"; exit }
      if (run == "busy") exit
      if (index(done, "|rerun " head "|") > 0) exit
      if (run == "none" || run == "") { print "cannot"; exit }
      print "rerun"
    }'
}

# unstick_rerun_note CAUSE HEAD
# The comment the drain's end leaves when it starts CI again on a pull
# request, ending with the mark that keeps it to once per head commit.
unstick_rerun_note() {
  printf 'The merge queue started CI again on this commit: its last run stopped for %s, not for anything in the change. It does this once per commit; if the run stops again, its agent looks at the cause.\n\n' "${1:-a cause outside the code}"
  unstick_mark rerun "$2"
}

# Held steps, recorded not remembered (scripts/ci/QUEUE.md, "Held steps").
# An agent that means to act after another pull request lands once kept the
# step in its head: a merge of main waited an hour past the landing it was
# waiting for, with the runners idle and nothing saying so. Now the wait is
# a comment on its pull request (scripts/ci/wait-for.sh) with a hidden mark
# the drain's end reads.

# after_mark AFTER STEP SESSION WORDS: the hidden line. STEP is merge-main
# (the queue merges main in itself once AFTER lands) or wake (its session
# does the step); SESSION is "-" when none was named; WORDS is the step in
# plain words. A line break in WORDS is a space.
after_mark() {
  printf '<!-- merge-queue:after %s %s %s | %s -->\n' "$1" "$(after_step "$2")" "${3:--}" "$(printf '%s' "$4" | tr '\r\n|' '   ' | sed 's/--*>/ /g; s/  */ /g; s/^ //; s/ $//')"
}

# after_step WORD: merge-main for "merge-main" or "merge main in", wake for anything else.
after_step() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in merge-main|"merge main"|"merge main in") echo merge-main ;; *) echo wake ;; esac
}

# after_done_mark AFTER: the line that marks every wait on AFTER done.
after_done_mark() {
  printf '<!-- merge-queue:after-done %s -->\n' "$1"
}

# after_marks COMMENTS
# COMMENTS is a pull request's comment bodies. Print one line per wait not
# yet marked done: "AFTER<TAB>STEP<TAB>SESSION<TAB>WORDS", the newest wait
# on each AFTER only.
after_marks() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    match($0, /<!-- merge-queue:after-done [0-9]+ -->/) { s = substr($0, RSTART, RLENGTH); split(s, w, " "); done[w[3]] = 1 }
    match($0, /<!-- merge-queue:after [0-9]+ [a-z-]+ [^ ]+ \| .* -->/) {
      s = substr($0, RSTART + 23, RLENGTH - 27); n = split(s, w, " ")
      words = s; sub(/^[^|]*\| ?/, "", words)
      if (!(w[1] in seen)) order[++k] = w[1]
      seen[w[1]] = 1; step[w[1]] = w[2]; ses[w[1]] = w[3]; say[w[1]] = words
    }
    END { for (i = 1; i <= k; i++) { a = order[i]; if (!(a in done)) printf "%s\t%s\t%s\t%s\n", a, step[a], ses[a], say[a] } }'
}

# after_action STEP LANDED BUSY: what the drain's end does for one wait.
# LANDED is yes when AFTER has merged; BUSY is unstick_busy. Print merge
# (merge main in through update-branch), wake (name the session in the
# report and mark it done), or nothing: not landed yet, or a merge of main
# while another pull request's CI runs, so two re-merges never run at once.
after_action() {
  [ "$2" = yes ] || return 0
  if [ "$1" = merge-main ]; then [ "$3" = yes ] || echo merge; else echo wake; fi
}

# after_wake_line PR AFTER SESSION WORDS: the drain report's line that wakes
# the session holding PR, which the session brief repeats.
after_wake_line() {
  if [ -n "$3" ] && [ "$3" != - ]; then w_who="session $3"; else w_who="its agent"; fi
  printf 'Wake: #%s waited for #%s, which has landed; %s takes the step now: %s\n' "$1" "$2" "$w_who" "${4:-the step it recorded}"
}

# after_note KIND AFTER WORDS: the comment the drain's end leaves when a
# wait is due, ending with the mark that closes it. KIND is merged (it
# merged main in) or wake.
after_note() {
  if [ "$1" = merged ]; then
    printf '#%s landed, so the merge queue merged main into this pull request, the step recorded here. CI runs on the new commit by itself.\n\n' "$2"
  else
    printf '#%s landed. The step recorded here is due now: %s\n\n' "$2" "${3:-the step it named}"
  fi
  after_done_mark "$2"
}

# rule_check_step NAME: "yes" when a failed CI step is a rule check on the
# change or its pull request (the CI template names each "Fail when ...", or
# runs one of the check scripts) or the report after a failure, never a
# test; "no" otherwise.
rule_check_step() {
  case "$1" in
    "Fail when"*|"Say what failed"*|"Name the failed job"*) echo yes ;;
    *mock-check*|*delete-check*|*spec-check*|*setup-check*|*shared-check*|*design-check*|*numbering-check*|*line-endings*|*private-names*) echo yes ;;
    *) echo no ;;
  esac
}

# retry_is_flake FAILED NOW_HEAD NOW_BODY: "yes" when a run that failed
# and then passed is a flake. FAILED is the failure's context, "head\tbody
# hash\tfailed steps" (the steps joined by ";", empty when unread). A flake
# needs the same head commit, the same pull request body, and a failed step
# that is a test: a rule check on the body that passed once the body was
# edited (a missing Mock: line, a deletion without a Deletes: line) is not
# an unreliable test, and was once filed as one. Unknown steps count as a
# test, so a failing test named from the log is still caught.
retry_is_flake() {
  rf_h=$(printf '%s' "$1" | cut -f1); rf_b=$(printf '%s' "$1" | cut -s -f2); rf_s=$(printf '%s' "$1" | cut -s -f3)
  if [ -z "$rf_h" ] || [ "$rf_h" != "$2" ] || [ "$rf_b" != "$3" ]; then echo no; return 0; fi
  [ -n "$rf_s" ] || { echo yes; return 0; }
  rf_old=$IFS; IFS=';'
  for rf_step in $rf_s; do
    IFS=$rf_old
    [ -n "$rf_step" ] || continue
    if [ "$(rule_check_step "$rf_step")" = no ]; then echo yes; return 0; fi
  done
  IFS=$rf_old
  echo no
}

