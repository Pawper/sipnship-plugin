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
