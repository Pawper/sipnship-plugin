#!/bin/sh
# Pure helpers for reading a CI run: telling GitHub's outage from our own
# failure, naming the failing check, noticing a canceled run, keeping the
# flaky-test record, and waiting for a quiet main. No gh calls here;
# merge-queue.sh gathers the lines and these decide.

# run_verdict JOBS NOW [IDLE_RUNNERS] [QUEUE_MINUTES]
# JOBS is one job per line: "name<TAB>status<TAB>conclusion<TAB>started_epoch<TAB>annotations".
# Print one of:
#   outage: ...     a job annotation says no hosted runner picked it up, or a
#                   job has sat queued for QUEUE_MINUTES (default 5) while
#                   IDLE_RUNNERS (default 0) of ours were idle
#   canceled: ...   a job was canceled
#   failed: a, b    the jobs that failed, by name
#   green           every job succeeded or was skipped
#   pending         still running
run_verdict() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v idle="${3:-0}" -v qmin="${4:-5}" '
    NF >= 3 {
      name = $1; status = $2; conc = $3; started = $4 + 0; ann = tolower($5)
      if (ann ~ /not acquired by runner|no runner|runner.*offline/) { outage = name ": " $5; next }
      if (status == "queued" && started > 0 && (now - started) > qmin * 60 && idle > 0) { outage = name ": queued for " int((now - started) / 60) " minutes while " idle " of our runners were idle"; next }
      if (conc == "cancelled" || conc == "canceled") { canceled = (canceled == "") ? name : canceled ", " name; next }
      if (conc == "failure" || conc == "timed_out" || conc == "action_required") { failed = (failed == "") ? name : failed ", " name; next }
      if (status != "completed") pending = 1
    }
    END {
      if (outage != "") print "outage: " outage
      else if (canceled != "") print "canceled: " canceled
      else if (failed != "") print "failed: " failed
      else if (pending) print "pending"
      else print "green"
    }'
}

# githubstatus_verdict JSON
# JSON is https://www.githubstatus.com/api/v2/components.json. Print
# "GitHub Actions: <status>" when the Actions component is not operational,
# nothing when it is or the text is empty.
githubstatus_verdict() {
  printf '%s' "$1" | tr -d '\n' | awk '
    {
      s = $0
      while (match(s, /"name":"[^"]*"/)) {
        name = substr(s, RSTART + 8, RLENGTH - 9)
        rest = substr(s, RSTART + RLENGTH)
        if (match(rest, /"status":"[^"]*"/)) status = substr(rest, RSTART + 10, RLENGTH - 11); else status = ""
        if (name == "Actions" && status != "" && status != "operational") { print "GitHub Actions: " status; exit }
        s = rest
      }
    }'
}

# failed_tests_from_log TEXT
# TEXT is the log of a failed run. Print the names of failing tests, one
# per line, unique, from the common runner formats:
#   vitest/jest:  "FAIL  src/a.test.ts > renders"  or  "× renders"  or  "✗ renders"
#   pytest:       "FAILED tests/test_a.py::test_x"
#   go:           "--- FAIL: TestX"
failed_tests_from_log() {
  printf '%s\n' "$1" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | awk '
    /^[ \t]*(FAIL|✗|×|✖)[ \t]+/ { t = $0; sub(/^[ \t]*(FAIL|✗|×|✖)[ \t]+/, "", t); sub(/[ \t]+[0-9]+ ?ms.*$/, "", t); if (t != "" && !seen[t]++) print t; next }
    /^[ \t]*FAILED[ \t]+[^ \t]+::/ { t = $2; if (!seen[t]++) print t; next }
    /^--- FAIL: / { t = $3; if (!seen[t]++) print t; next }'
}

# flaky_log_add LOG DATE PR TEST RESULT
# Print LOG with one line appended: "DATE<TAB>PR<TAB>TEST<TAB>RESULT".
flaky_log_add() {
  printf '%s\n' "$1" | sed '/^$/d'
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5"
}

# flaky_offenders LOG [THRESHOLD]
# A flake is a test that failed and then passed on the same pull request.
# Print each test with at least THRESHOLD (default 2) flakes:
#   "COUNT<TAB>TEST<TAB>PR,PR,..."  most first.
flaky_offenders() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v th="${2:-2}" '
    NF >= 4 {
      k = $3 SUBSEP $2
      if ($4 == "failed") failed[k] = 1
      else if ($4 == "passed" && (k in failed)) { if (!(k in counted)) { counted[k] = 1; n[$3]++; prs[$3] = (prs[$3] == "") ? $2 : prs[$3] "," $2 } }
    }
    END { for (t in n) if (n[t] >= th) printf "%d\t%s\t%s\n", n[t], t, prs[t] }' | sort -rn
}

# main_in_flight RUNS
# RUNS is one run per line: "id<TAB>branch<TAB>status<TAB>event". Print
# "yes" when a run on main is queued or in progress, "no" otherwise.
main_in_flight() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 3 && $2 == "main" && ($3 == "queued" || $3 == "in_progress" || $3 == "waiting" || $3 == "requested") { f = 1 }
    END { print f ? "yes" : "no" }'
}

# stuck_runs RUNS NOW [MINUTES]
# RUNS is one run per line: "id<TAB>workflow<TAB>branch<TAB>status<TAB>created_epoch".
# Print the runs that have sat queued for more than MINUTES (default ten),
# oldest first: "id<TAB>workflow<TAB>branch<TAB>minutes". A run that waits
# that long for a runner is a runner problem, not a slow test.
stuck_runs() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v lim="${3:-10}" '
    NF >= 5 && ($4 == "queued" || $4 == "waiting" || $4 == "pending") && ($5 + 0) > 0 {
      m = int((now - $5) / 60)
      if (m > lim) printf "%d\t%s\t%s\t%s\t%d\n", m, $1, $2, $3, m
    }' | sort -rn | cut -f2-
}

# runner_problems RUNNERS
# RUNNERS is one self-hosted runner per line: "name<TAB>status<TAB>busy".
# Print one plain line per runner that is offline, and one line when fewer
# than two are online, since a single runner is a queue of one.
runner_problems() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 2 { total++; if ($2 == "online") on++; else printf "Runner %s is %s.\n", $1, $2 }
    END { if (total > 0 && on < 2) printf "Only %d of %d self-hosted runner(s) online; one runner makes every job wait for the last.\n", on, total }'
}
