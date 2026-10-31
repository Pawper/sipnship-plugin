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
}

# The annotation a failing job writes, as a workflow command: the title
# names the job and the step, the message holds the lines.
failure_annotation() {
  fa_msg=$(printf '%s\n' "${3:-No test output was kept; the job log has the details.}" | awk '{ gsub(/%/, "%25"); gsub(/\r/, ""); printf "%s%s", (NR > 1 ? "%0A" : ""), $0 }')
  printf '::error title=%s failed at %s::%s\n' "$1" "${2:-unknown}" "$fa_msg"
}

# The report job's summary: each failed job with its step and lines, then
# the jobs cancelled because of it. LINES holds "job-name<TAB>message" lines
# read back from the failed jobs' annotations.
run_report() {
  printf '%s\n' "$1" | awk -F '\t' -v lines="$2" '
    BEGIN { n = split(lines, L, "\n")
            for (i = 1; i <= n; i++) { t = index(L[i], "\t"); if (t) { k = substr(L[i], 1, t - 1); msg[k] = msg[k] substr(L[i], t + 1) "\n" } } }
    $4 == "failure" { f++
      out = out sprintf("### %s failed\n\nThe step that failed: %s\n\n", $2, ($6 == "" ? "unknown" : $6))
      if (msg[$2] != "") out = out "```\n" msg[$2] "```\n\n" }
    $4 == "cancelled" { c = c "- " $2 "\n" }
    END { if (!f) { print "No job failed."; exit }
          printf "%s", out
          if (c != "") printf "Cancelled because of it:\n\n%s", c }'
}
