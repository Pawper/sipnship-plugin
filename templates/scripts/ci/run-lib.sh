#!/bin/sh
# Pure helpers for reading a CI run: telling GitHub's outage from our own
# failure, naming the failing check, noticing a canceled run, keeping the
# flaky-test record, and waiting for a quiet main. No gh calls here;
# merge-queue.sh gathers the lines and these decide.

# run_verdict JOBS NOW [IDLE_RUNNERS] [QUEUE_MINUTES]
# JOBS is one job per line: "name<TAB>status<TAB>conclusion<TAB>started_epoch<TAB>annotations".
# Print one of:
#   billing: name   GitHub refused to start the job on a hosted machine for
#                   billing (payments failed or the spending limit reached)
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
      if (ann ~ /recent account payments have failed|spending limit needs to be increased/) { billing = (billing == "") ? name : billing ", " name; next }
      if (ann ~ /not acquired by runner|no runner|runner.*offline/) { outage = name ": " $5; next }
      if (status == "queued" && started > 0 && (now - started) > qmin * 60 && idle > 0) { outage = name ": queued for " int((now - started) / 60) " minutes while " idle " of our runners were idle"; next }
      if (conc == "cancelled" || conc == "canceled") { canceled = (canceled == "") ? name : canceled ", " name; next }
      if (conc == "failure" || conc == "timed_out" || conc == "action_required") { failed = (failed == "") ? name : failed ", " name; next }
      if (status != "completed") pending = 1
    }
    END {
      if (billing != "") print "billing: " billing
      else if (outage != "") print "outage: " outage
      else if (canceled != "") print "canceled: " canceled
      else if (failed != "") print "failed: " failed
      else if (pending) print "pending"
      else print "green"
    }'
}

# billing_refused TEXT
# "yes" when TEXT, a job's annotations or a run's log, says GitHub refused
# to start a hosted job for billing: the account's payments failed or its
# spending limit is reached. Nothing otherwise. The run then fails with no
# step run, and one project's release was skipped for days with no word.
billing_refused() {
  printf '%s' "$1" | tr -d '\r' | grep -qiE 'recent account payments have failed|spending limit needs to be increased' && echo yes
  return 0
}

# billing_line WHAT
# The one plain line for that refusal, said by the queue, the brief and the
# audit alike. WHAT names what could not start ("the Deploy workflow").
billing_line() {
  printf 'Hosted Actions minutes are used up: GitHub refused to start %s for billing (a payment failed or the spending limit is reached). Nothing hosted starts until billing is settled at github.com/settings/billing, or the job moves onto a runner of this project'"'"'s own.\n' "$1"
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

# runner_count RUNNERS_JSON
# The runners a project wants, from .claude/runners.json ("runners": N);
# 3 when the file is missing or says nothing: two for CI side by side and
# one a drain may hold while it waits.
runner_count() {
  rc=$(printf '%s\n' "$1" | tr -d '\r' | sed -n 's/.*"runners"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
  echo "${rc:-3}"
}

# runner_status RUNNERS WANT
# RUNNERS is one self-hosted runner per line, "name<TAB>status<TAB>busy".
# One line for the brief and the doctor: "3 of 3 online", or "2 of 3
# online; sipnship-3 offline", or "2 of 3 wanted are registered; 2 online".
runner_status() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v want="${2:-3}" '
    NF >= 2 { total++; if ($2 == "online") on++; else off = off (off == "" ? "" : ", ") $1 " " $2 }
    END {
      if (total == 0) { printf "no runner registered; %d wanted\n", want; exit }
      if (total < want) printf "%d of %d wanted are registered; %d online", total, want, on
      else printf "%d of %d online", on, total
      if (off != "") printf "; %s", off
      printf "\n"
    }'
}

# load_verdicts SAMPLE WANT
# SAMPLE is one line: "cpu_pct<TAB>mem_pct<TAB>disk_free_gb<TAB>jobs_running
# <TAB>wait_min<TAB>runners_here<TAB>cores" (wait_min: how long jobs waited
# for a runner on average lately; runners_here: every project's runners on
# this machine). Print one "id|sentence" per condition that holds, in the
# builder's words; nothing when the machine is fine. The ids let the watch
# say a condition once when it starts and once when it ends.
load_verdicts() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v want="${2:-3}" '
    NF >= 7 {
      cpu = $1 + 0; mem = $2 + 0; disk = $3 + 0; jobs = $4 + 0; wait = $5 + 0; here = $6 + 0; cores = $7 + 0
      if (wait >= 5 && cpu < 50) printf "idle-wait|jobs waited %d minutes on average and the processor was %d%% busy; one more runner would help\n", wait, cpu
      if (wait >= 5 && cpu >= 85) printf "saturated|jobs waited %d minutes on average while the processor was %d%% busy with %d running; more runners would make each job slower: fewer runners, or a second machine\n", wait, cpu, jobs
      if (cpu >= 85 && wait < 5 && jobs > 0) printf "busy|the processor was %d%% busy with %d jobs running; fine while nothing waits\n", cpu, jobs
      if (mem >= 90) printf "memory|memory is %d%% used with %d jobs running and %d runners on this machine\n", mem, jobs, here
      if (disk < 5) printf "disk-urgent|only %d GB free on the runners'"'"' drive; a checkout can fail any time\n", disk
      else if (disk < 15) printf "disk|%d GB free on the runners'"'"' drive; runner work folders grow with every checkout\n", disk
      if (cores > 0 && here > cores / 2) printf "overcommit|%d runners on %d cores across the projects on this machine; past one runner per two cores each job slows the others\n", here, cores
    }'
}

# watch_changes PREV NOW
# PREV and NOW are "id|sentence" lines. Print "started: sentence" for an id
# in NOW but not PREV and "ended: sentence" for one in PREV but not NOW,
# so the watch speaks only when something changes, never on every run.
watch_changes() {
  printf '%s\n' "$2" | while IFS='|' read -r id text; do
    [ -n "$id" ] || continue
    printf '%s\n' "$1" | grep -q "^$id|" || printf 'started: %s\n' "$text"
  done
  printf '%s\n' "$1" | while IFS='|' read -r id text; do
    [ -n "$id" ] || continue
    printf '%s\n' "$2" | grep -q "^$id|" || printf 'ended: %s\n' "$text"
  done
}

# cron_runs_month CRON
# Roughly how many times a month a cron line fires: "*/30 * * * *" is
# 1,440, "17 */2 * * *" 360, "17 3 * * *" 30, "41 */6 * * *" 120. Lines
# it cannot read count as daily.
cron_runs_month() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    {
      gsub(/"/, ""); n = split($0, f, /[ \t]+/)
      if (n < 5) { print 30; exit }
      min = f[1]; hr = f[2]; dom = f[3]
      perday = 1
      if (min ~ /^\*\/[0-9]+$/) { split(min, a, "/"); perday = (60 / a[2]) * 24 }
      else if (min == "*") perday = 1440
      else if (hr ~ /^\*\/[0-9]+$/) { split(hr, a, "/"); perday = 24 / a[2] }
      else if (hr == "*") perday = 24
      days = 30
      if (dom ~ /^\*\/[0-9]+$/) { split(dom, a, "/"); days = 30 / a[2] }
      print int(perday * days + 0.5)
    }'
}

# hosted_estimate WORKFLOWS
# WORKFLOWS is one line per workflow job that runs hosted in this project:
# "file<TAB>cron-or-empty<TAB>events" where events is the per-event
# triggers (issues, pull_request), comma separated or empty. Print one
# sentence estimating the month: scheduled runs at one billed minute each
# (a job bills at least a minute), plus "one a <event>" for the rest;
# nothing when WORKFLOWS is empty.
hosted_estimate() {
  [ -n "$(printf '%s' "$1" | tr -d ' \n\r')" ] || return 0
  he_total=0; he_files=""; he_events=""
  while IFS="$(printf '\t')" read -r f cron events; do
    [ -n "$f" ] || continue
    he_files="$he_files${he_files:+, }$(basename "$f" .yml)"
    if [ -n "$cron" ]; then he_total=$((he_total + $(cron_runs_month "$cron"))); fi
    if [ -n "$events" ]; then he_events="$he_events${he_events:+, }$(basename "$f" .yml) once per $(printf '%s' "$events" | tr ',' '/')"; fi
  done <<HEEOF
$1
HEEOF
  printf 'hosted Actions: %s run hosted in this private repository, about %s scheduled minutes a month%s; the free allowance is 2,000 and is shared by every repository on the account\n' "$he_files" "$(printf '%d' "$he_total" | sed ':a;s/\([0-9]\)\([0-9][0-9][0-9]\)\b/\1,\2/;ta')" "${he_events:+ plus $he_events}"
}

# hosted_jobs WORKFLOW_FILE TEXT
# For one workflow: a "file<TAB>cron<TAB>events" line when it has a job on
# a hosted runner (ubuntu-, windows-, macos-latest) that no "if:" on a
# variable gates; nothing otherwise. Comments are ignored.
hosted_jobs() {
  printf '%s\n' "$2" | tr -d '\r' | awk -v f="$1" '
    /^[ \t]*#/ { next }
    # Triggers are read only inside the "on:" block: "issues: write" under
    # permissions once counted as an issues trigger.
    /^on:/ { inon = 1; next }
    /^[A-Za-z]/ { inon = 0 }
    /^[ \t]*runs-on:[ \t]*(ubuntu|windows|macos)-/ { hosted = 1 }
    # The HOSTED_MINUTES guard is not a choice to run hosted: still counted.
    /^[ \t]*if:[ \t]*.*vars\./ { g = $0; gsub(/vars\.HOSTED_MINUTES/, "", g); if (g ~ /vars\./) gated = 1 }
    inon && /^[ \t]*-[ \t]*cron:/ { c = $0; sub(/^[ \t]*-[ \t]*cron:[ \t]*/, "", c); gsub(/["\047]/, "", c); cron = c }
    inon && /^  (issues|pull_request|push|issue_comment|deployment_status|workflow_run):/ { e = $1; sub(/:$/, "", e); events = events (events == "" ? "" : ",") e }
    END { if (hosted && !gated) printf "%s\t%s\t%s\n", f, cron, events }'
}

# quota_gone ANNOTATIONS
# ANNOTATIONS is the text of a run's annotations, one per line. In a private
# repository whose hosted minutes are used up, or whose spending limit is
# zero, GitHub does not start a hosted job and leaves one annotation saying
# so. Print one plain line when it does; nothing otherwise. A hosted job
# gated on "vars.HOSTED_MINUTES != 'gone'" then ends as skipped, not failed.
quota_gone() {
  printf '%s\n' "$1" | tr -d '\r' | grep -qiE 'spending limit needs to be increased|recent account payments have failed' || return 0
  printf "%s\n" "Hosted runs are not starting: this account's hosted minutes are used up or its spending limit is zero, so every hosted job fails before it begins. Its hosted jobs end as skipped instead once the repository variable says so: gh variable set HOSTED_MINUTES --body gone (delete it when minutes are back)."
}

# stuck_line STUCK
# STUCK is stuck_runs output. One plain line for the session brief, or
# nothing: the oldest run, and how many more wait with it.
stuck_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 4 { n++; if (n == 1) { w = $2; b = $3; m = $4 } }
    END { if (n) printf "Queued: %s on %s has waited %s minutes for a runner%s; start the runners (scripts/ci/RUNNERS.md).\n", w, b, m, (n > 1 ? sprintf(", and %d more", n - 1) : "") }'
}

# machine_line CORES HERE BUSY
# The machine in one line: its cores, the runners registered on it across
# every repository, how many are running a job now, and how many the rule
# allows (one runner per two cores).
machine_line() {
  ml_c=${1:-0}; ml_h=${2:-0}; ml_b=${3:-0}
  printf '%s cores, %s runner(s) on this machine across repositories, %s busy now; the rule allows %s (one per two cores)\n' "$ml_c" "$ml_h" "$ml_b" $(( ml_c / 2 ))
}

# machine_over CORES HERE: how many runners past the rule; 0 within it.
machine_over() {
  mo_a=$(( ${1:-0} / 2 )); mo_h=${2:-0}
  if [ "${1:-0}" -gt 0 ] && [ "$mo_h" -gt "$mo_a" ]; then echo $(( mo_h - mo_a )); else echo 0; fi
}
