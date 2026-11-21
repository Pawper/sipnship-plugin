# Pure parts of failure-report.sh: what a failing job writes about itself,
# and what the report job says about the run. No network; the jobs come in
# as tab-separated lines:
#   id  name  status  conclusion  runner  failed-step

# The job this runner is running: in progress on RUNNER.
own_job() {
  printf '%s\n' "$1" | awk -F '\t' -v r="$2" '$3 == "in_progress" && $5 == r { print; exit }'
}

# The job summary a failing job writes: its name, the step and the lines.
failure_summary() {
  printf '### %s failed\n\nThe step that failed: %s\n\n' "$1" "${2:-unknown}"
  if [ -n "$3" ]; then printf 'Its last lines:\n\n```\n%s\n```\n' "$3"
  else printf 'No test output was kept; the job log has the details.\n'; fi
  # A block over its time limit, beside the real cause: nothing fails on time.
  if [ -n "$4" ]; then printf '\nAlso slow, and not the cause:\n\n%s\n' "$4"; fi
}

# failure_lines LOG TAIL
# The lines a failing job writes about itself: TAIL (its log's last lines),
# led by the failing tests named anywhere in LOG that TAIL does not show, one
# "FAIL  file > test" line each (at most five). A test that printed a lot
# after it failed (a stylesheet, a stack) once left only that output in the
# last lines, so the cause had to be dug out of the job's log by hand; the
# failing test now comes first, in the form the dashboard and the queue read.
# Needs failed_tests_from_log (run-lib.sh).
failure_lines() {
  fl_lead=$(failed_tests_from_log "$1" | head -n 5 | while IFS= read -r fl_t; do
    [ -n "$fl_t" ] || continue
    printf '%s\n' "$2" | grep -qF -e "$fl_t" || printf 'FAIL  %s\n' "$fl_t"
  done)
  if [ -n "$fl_lead" ]; then printf '%s\n%s\n' "$fl_lead" "$2"; else printf '%s\n' "$2"; fi
}

# The annotation a failing job writes, as a workflow command: the title
# names the job and the step, the message holds the lines.
failure_annotation() {
  fa_slow=${4:+"
Also slow, and not the cause: $4"}
  fa_msg=$(printf '%s\n' "${3:-No test output was kept; the job log has the details.}$fa_slow" | awk '{ gsub(/%/, "%25"); gsub(/\r/, ""); printf "%s%s", (NR > 1 ? "%0A" : ""), $0 }')
  printf '::error title=%s failed at %s::%s\n' "$1" "${2:-unknown}" "$fa_msg"
}

# The report job's summary: each failed job with its step and lines, then
# the jobs cancelled because of it. LINES holds "job-name<TAB>message" lines
# read back from the failed jobs' annotations. A job cancelled with a step
# of its own failed is a failed job: the checks job cancels its own run
# after a failed check, which marks it cancelled.
run_report() {
  printf '%s\n' "$1" | awk -F '\t' -v lines="$2" '
    BEGIN { n = split(lines, L, "\n")
            for (i = 1; i <= n; i++) { t = index(L[i], "\t"); if (t) { k = substr(L[i], 1, t - 1); msg[k] = msg[k] substr(L[i], t + 1) "\n" } } }
    $4 == "failure" || ($4 == "cancelled" && $6 != "") { f++
      out = out sprintf("### %s failed\n\nThe step that failed: %s\n\n", $2, ($6 == "" ? "unknown" : $6))
      if (msg[$2] != "") out = out "```\n" msg[$2] "```\n\n"; next }
    $4 == "cancelled" { c = c "- " $2 "\n" }
    END { if (!f) { print "No job failed."; exit }
          printf "%s", out
          if (c != "") printf "Cancelled because of it:\n\n%s", c }'
}

# run_verdict JOBS
# "failed" when a job failed, or was cancelled after one of its own steps
# failed; "stopped" when jobs were cancelled and nothing failed (a rush or a
# hold made room, and they run again); "none" otherwise. The summary job
# words its error by it, so a stopped run never reads as a failed check.
run_verdict() {
  printf '%s\n' "$1" | awk -F '\t' '
    $4 == "failure" || ($4 == "cancelled" && $6 != "") { f = 1 }
    $4 == "cancelled" && $6 == "" { c = 1 }
    END { print (f ? "failed" : c ? "stopped" : "none") }'
}

# slow_say LOG
# The plain words for a test block whose time line was over its limit, read
# from the log's WARN lines ("WARN  the block "X" took 70s, over its limit of
# 60s (...)", or "WARN  X took 20s, over its limit of 15s (...)"). One line
# per block, naming how much over. Nothing fails on time, so a run that went
# red for another reason says it beside the real cause, and the reader does
# not go looking for a time gate that is no longer there.
slow_say() {
  printf '%s\n' "$1" | awk '
    /^WARN +.* took [0-9]+s, over its limit of [0-9]+s/ {
      s = $0; sub(/^WARN +/, "", s)
      i = match(s, / took [0-9]+s, over its limit of [0-9]+s/)
      name = substr(s, 1, i - 1); rest = substr(s, i + 6)
      gsub(/^the block "|"$/, "", name)
      took = rest + 0; j = index(rest, "limit of "); lim = substr(rest, j + 9) + 0
      printf "%s was slow: it took %ds, %ds over its limit of %ds. Nothing fails on time; the cause is the failed step.\n", name, took, took - lim, lim
    }'
}

# failed_others JOBS SELF
# The names of the jobs that failed (a failed job, or a cancelled one with a
# step of its own that failed), SELF left out, comma-separated, in the order
# they ended (the report sorts JOBS by end time). Read from the same tab lines.
failed_others() {
  printf '%s\n' "$1" | awk -F '\t' -v me="$2" '
    ($4 == "failure" || ($4 == "cancelled" && $6 != "")) && $2 != me { out = out (out == "" ? "" : ", ") $2 }
    END { print out }'
}

# stopped_say PART SECONDS LIMIT OTHERS
# What a test part says when the run stops it: SECONDS is how long it had run,
# LIMIT its time limit in minutes, OTHERS the jobs that failed (failed_others).
# Only a part that reached its limit says it ran out of time; one stopped
# sooner was stopped from outside, because another part failed when OTHERS
# names one (the matrix cancels its siblings), and says how long it ran.
stopped_say() {
  if [ "${2:-0}" -ge $(( ${3:-180} * 60 )) ]; then
    printf 'The %s part ran out of its %s minutes.' "$1" "$3"; return 0
  fi
  if [ "${2:-0}" -lt 60 ]; then ss_ran="${2:-0} seconds"; else ss_ran="$(( $2 / 60 )) minutes"; fi
  if [ -n "$4" ]; then
    printf 'The %s part was stopped because another part failed (%s), after %s. It did not fail and did not run out of time.' "$1" "$4" "$ss_ran"
  else
    printf 'The %s part was stopped from outside after %s. It did not run out of time.' "$1" "$ss_ran"
  fi
}
