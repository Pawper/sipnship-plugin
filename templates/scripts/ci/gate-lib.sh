# Pure parts of gate.sh: main's full gate, after a quiet hour. Main gets no
# run per landing; each landing's own green pull-request run is its record.
# Once an hour a scheduled run asks gate_decide whether to run every test
# part of every class. No network here.

# gate_decide HEAD LAST_GATED PUSHED_EPOCH NOW_EPOCH QUIET_MINUTES [EVENT]
# "run" or "skip: <why>". It runs when main's head is not the last head a
# gate ran on and main has been quiet (no landing) for QUIET_MINUTES. A
# workflow_dispatch run always runs.
gate_decide() {
  [ "${6:-}" = workflow_dispatch ] && { echo run; return; }
  if [ -n "$2" ] && [ "$1" = "$2" ]; then echo "skip: main has not moved since the last gate"; return; fi
  [ -n "$3" ] || { echo "skip: main's last landing time is not known"; return; }
  gd_ago=$(( ($4 - $3) / 60 ))
  if [ "$gd_ago" -lt "$5" ]; then echo "skip: main moved $gd_ago minutes ago; the gate waits for $5 quiet minutes"; return; fi
  echo run
}

# gate_skip_early HEAD PUSHED_EPOCH NOW_EPOCH QUIET_MINUTES [EVENT]
# The skip that needs no look at past runs: main moved inside the quiet time,
# or its landing time is not known. Prints "skip: <why>", or nothing when the
# past runs must be read to decide. The gate asks this first, so a main that
# is not due ends in seconds, on the one call that read main.
gate_skip_early() {
  gse=$(gate_decide "$1" "" "$2" "$3" "$4" "${5:-}")
  case "$gse" in skip*) echo "$gse" ;; esac
}

# last_gated RUNS: the newest gate that ran its tests, or failed before its
# tests existed, from lines of
#   head-sha  conclusion  created-epoch  tests-ran(yes|no)
# newest first; prints "head-sha<TAB>conclusion<TAB>created-epoch", or
# nothing. A run whose gate skipped is not a gate. A run that failed with no
# test job at all counts as red, not as absent: GitHub reports no failed
# step for it, and main was not checked.
last_gated() {
  printf '%s\n' "$1" | awk -F '\t' '($4 == "yes" && ($2 == "success" || $2 == "failure")) || ($4 == "no" && $2 == "failure") { print $1 "\t" $2 "\t" $3; exit }'
}

# gate_last_why RUNS: "nostart" when the gate last_gated names failed with no
# test job started: a red run with no failed job, which is not a failed test
# (the Main card says the check could not start its jobs, and it is the
# machines' turn); nothing otherwise.
gate_last_why() {
  printf '%s\n' "$1" | awk -F '\t' '($4 == "yes" && ($2 == "success" || $2 == "failure")) || ($4 == "no" && $2 == "failure") { if ($4 == "no") print "nostart"; exit }'
}

# last_gated_ran RUNS: as last_gated, but only a gate whose tests ran. The
# decision to run again reads this, so a head whose gate failed before its
# tests is tried again.
last_gated_ran() {
  printf '%s\n' "$1" | awk -F '\t' '$4 == "yes" && ($2 == "success" || $2 == "failure") { print $1 "\t" $2 "\t" $3; exit }'
}

# gate_early_red_count RUNS: how many of the newest runs in a row failed
# before their test jobs existed (conclusion failure, tests-ran "no"), from
# the same lines as last_gated. A run whose tests ran ends the count; a
# skipped or cancelled run is passed over. The job that opens the red-main
# issue needs the test jobs, so nothing else says it.
gate_early_red_count() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F '\t' '
    NF < 4 || done { next }
    $2 == "failure" && $4 == "no" { n++; next }
    $2 == "cancelled" || ($4 == "no" && $2 == "success") { next }
    { done = 1 }
    END { print n + 0 }'
}

# gate_early_red_line RUNS: "main's gate at HH:MM ended red before its tests
# started; nothing has checked main since HH:MM", or nothing when no gate
# failed early since the last one whose tests ran. Times are the machine's
# local clock.
gate_early_red_line() {
  [ "$(gate_early_red_count "$1")" -gt 0 ] || return 0
  ge_red=$(printf '%s\n' "$1" | tr -d '\r' | awk -F '\t' 'NF >= 4 && $2 == "failure" && $4 == "no" { print $3; exit }')
  ge_ok=$(last_gated_ran "$(printf '%s\n' "$1" | tr -d '\r')" | cut -f3)
  ge_at() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null; }
  if [ -n "$ge_ok" ]; then
    echo "main's gate at $(ge_at "$ge_red") ended red before its tests started; nothing has checked main since $(ge_at "$ge_ok")."
  else
    echo "main's gate at $(ge_at "$ge_red") ended red before its tests started; no gate has checked main on record."
  fi
}

# gate_early_red_run RUNS: the id of the newest run that ended red before its
# test jobs existed, from RUNS' fifth column; nothing when none did.
gate_early_red_run() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F '\t' 'NF >= 5 && $2 == "failure" && $4 == "no" { print $5; exit }'
}

# red_kind GATE FULL TESTS: what kind of red a main run was, from the results
# of its jobs (success, failure, cancelled, skipped, or empty for a job that
# was never created): "test" when a test job failed, "nostart" when the run
# is red and no test job failed (GitHub did not start them, or the gate
# itself failed), "unfinished" when a job was cancelled and none failed;
# nothing when the run is not red.
red_kind() {
  case "$2$3" in *failure*) echo test; return ;; esac
  case "$1" in failure) echo nostart; return ;; esac
  case "$1$2$3" in *cancelled*) echo unfinished ;; esac
}

# rerun_note SHA: the line left on the red-main issue when the check is
# started again for a commit; rerun_due looks for it.
rerun_note() {
  printf 'Started the check again for %s, once; it is not started again for this commit.' "$(printf '%s' "$1" | cut -c1-7)"
}

# rerun_due KIND SHA COMMENTS: "yes" when a red main run of kind "nostart"
# (the check could not start its jobs: nothing wrong with main's code) may be
# started again: once per commit. COMMENTS are the red-main issue's comments;
# one that already says the check was started again for this commit makes it
# "no". Any other kind is "no": a failed test is the builder's, and is not
# run again to see if it passes.
rerun_due() {
  [ "$1" = nostart ] || { echo no; return; }
  if printf '%s\n' "$3" | tr -d '\r' | grep -qF "$(rerun_note "$2")"; then echo no; else echo yes; fi
}

# red_words KIND: the kind in plain words, as the Main card says it.
red_words() {
  case "$1" in
    test) echo "a test failed" ;;
    nostart) echo "the check could not start its jobs" ;;
    unfinished) echo "the check did not finish" ;;
    *) echo "the check was red" ;;
  esac
}

# red_note KIND SHA URL SECOND: the comment on the red-main issue for one red
# run. A run that is not a failed test is the machines' turn and says so;
# SECOND is "yes" when the run before it was red the same way, which the
# runner watch is told by this line.
red_note() {
  rn_head="Main's check on ${2} was red: $(red_words "$1"). Run: $3."
  case "$1" in
    test) printf '%s Fix it before merging anything else.\n' "$rn_head" ;;
    *)
      printf '%s No test failed, and nothing is asked of the owner.' "$rn_head"
      if [ "$4" = yes ]; then printf ' This is the second run in a row that was red this way, so the runner watch is told: the machines need a look.\n'
      else printf ' The check is run once more by itself at the next hour.\n'; fi ;;
  esac
}

# gate_holds_deploy GATED LANDED_EPOCH: the reason a deploy is held, or
# nothing. GATED is last_gated's line. Only a red gate newer than the
# head's landing holds; a head that landed after it carries its own green
# landing run and goes.
gate_holds_deploy() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | awk -F '\t' -v landed="$2" '$2 == "failure" && (landed == "" || $3 + 0 >= landed + 0) { print "main'\''s full gate is red on " substr($1, 1, 7) " and nothing landed since" }'
}

# gate_main_state GATED: main's state as the last gate saw it: "green" or
# "red", or "unknown" when no gate has run its tests yet. GATED is
# last_gated's line. Main gets no run per landing, so this is the one place
# its state is read; the newest push run of CI is not a record of main.
gate_main_state() {
  printf '%s\n' "$1" | awk -F '\t' 'NF >= 3 && $2 == "success" { print "green"; f = 1; exit } NF >= 3 && $2 == "failure" { print "red"; f = 1; exit } END { if (!f) print "unknown" }'
}

# gate_checked_at GATED: the time main was last fully checked, as an ISO
# UTC time, or nothing when no gate has run.
gate_checked_at() {
  gc_e=$(printf '%s\n' "$1" | awk -F '\t' 'NF >= 3 && $3 + 0 > 0 { print $3; exit }')
  [ -n "$gc_e" ] || return 0
  date -u -d "@$gc_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$gc_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# main_unassigned RUNS NOW IDLE
# RUNS is main_in_flight's lines with the created epoch as a fifth field.
# Print "id<TAB>minutes" for each push run on main that has sat queued
# over ten minutes while the runners were idle (IDLE "yes"): GitHub has not
# handed it to a machine, so the wait is GitHub's, not a runner's.
main_unassigned() {
  [ "${3:-}" = yes ] || return 0
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" '
    NF >= 5 && $2 == "main" && $4 == "push" && ($3 == "queued" || $3 == "waiting" || $3 == "requested") && $5 + 0 > 0 && now - $5 > 600 { printf "%s\t%d\n", $1, int((now - $5) / 60) }'
}

# main_waiting_said UNASSIGNED: the dashboard's plain line for
# main_unassigned's output ("id<TAB>minutes"), or nothing.
main_waiting_said() {
  mw=$(printf '%s\n' "$1" | awk -F '\t' 'NF >= 2 { print $2; exit }')
  [ -n "$mw" ] || return 0
  echo "A run on main has waited $mw minutes with every runner idle: waiting on GitHub, not on a machine."
}

# gate_failing_tests LINES [MAX]
# The names of the tests a failed gate run lists, for the dashboard's red
# Main card. LINES is "job-name<TAB>line" per line, read from the failed
# jobs' annotations (failure-report.sh writes each job's last lines there).
# Prints "part: test" per failing test, at most MAX (default 5), unique. The
# part is the matrix part in the job's parentheses ("tests (shell-1)" is
# shell-1), else the whole job name. A runner line is "FAIL  file > test",
# "FAIL  test", "x test", "FAILED path::test" or "--- FAIL: TestX"; the file
# before " > " is left off, so a person reads the test's own words.
gate_failing_tests() {
  printf '%s\n' "$1" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | awk -F '\t' -v max="${2:-5}" '
    NF >= 2 {
      job = $1; line = $2
      part = job
      if (match(job, /\([^)]*\)/)) part = substr(job, RSTART + 1, RLENGTH - 2)
      t = ""
      if (line ~ /^[ ]*(FAIL|✗|×|✖)[ ]+/) { t = line; sub(/^[ ]*(FAIL|✗|×|✖)[ ]+/, "", t); sub(/[ ]+[0-9]+ ?ms.*$/, "", t) }
      else if (line ~ /^[ ]*FAILED[ ]+[^ ]+::/) { t = line; sub(/^[ ]*FAILED[ ]+/, "", t); sub(/^[^:]*::/, "", t) }
      else if (line ~ /^--- FAIL: /) { t = line; sub(/^--- FAIL: /, "", t); sub(/ .*$/, "", t) }
      if (t == "") next
      n = split(t, segs, " > "); if (n > 1) t = segs[n]
      sub(/^[ ]+/, "", t); sub(/[ ]+$/, "", t)
      key = part ": " t
      if (t != "" && !(key in seen) && count < max) { seen[key] = 1; count++; print key }
    }'
}

# last_gated_run RUNS: the run id of the newest gate that ran its tests, from
# the same lines as last_gated with the run id as a fifth field.
last_gated_run() {
  printf '%s\n' "$1" | awk -F '\t' '$4 == "yes" && ($2 == "success" || $2 == "failure") { print $5; exit }'
}

# full_run_decide HEAD_REF LABELS CLASSES
# "yes" when a pull request's own run is a full run, otherwise "no". Batch
# first: a pull request's own CI is the cheap gate (the checks job and
# classify), and its test parts and app run once, in the batch, current with
# main. A full run of its own: a batch or rush head (the batch's one run is
# the full one), a "ci:full" label (read when the run starts), or a change
# to CI itself (.github/ or scripts/ci/, the class "ci"), since it changes
# the gate and nothing else proves it. LABELS is comma separated and CLASSES
# space separated.
full_run_decide() {
  case "$1" in batch-*|rush-*) echo yes; return ;; esac
  case ",$2," in *,ci:full,*) echo yes; return ;; esac
  case " $3 " in *" ci "*) echo yes; return ;; esac
  echo no
}

# cheap_gate_say: what a green pull request that has run only its rule
# checks is told, in the words a person reads (the Queue and Work cards).
cheap_gate_say() { echo "Its rule checks passed; it lands with the next batch"; }

# cheap_gate_held CHECKS: "yes" when a pull request's check lines show the
# cheap gate and no test jobs: the "checks" job passed and every "tests",
# "app" and "screens" job is skipped or absent. CHECKS is the text of
# scripts/pr-checks.sh, one "  name   outcome" line per check run.
cheap_gate_held() {
  printf '%s\n' "$1" | awk '
    $1 == "checks" && $2 == "success" { c = 1 }
    $1 == "tests" || $1 == "app" || $1 == "screens" { if ($2 != "skipped") other = 1 }
    END { print (c && !other) ? "yes" : "no" }'
}

# gate_early_read_due WHY: "no" when the gate decision WHY (gate.sh decide) stood
# aside on the one call that read main (main moved inside the quiet time, its
# landing time or itself unreadable): the run then ends in seconds and reads no
# past runs. "yes" for any other decision.
gate_early_read_due() {
  case "$1" in
    "skip: main moved "*|"skip: main's last landing time is not known"|"skip: main cannot be read") echo no ;;
    *) echo yes ;;
  esac
}
