# Pure parts of the flake record (report-flake.sh, flaky-audit.sh): text in,
# text out. A red main the very next run clears with no fix is a flake.

# flake_decision TEXT: "yes" when TEXT, the red-main issue's body and comments,
# holds exactly one red run and no flake note yet: the very next run on main
# went green with no fix, which is a flake. A fix lands by closing the issue,
# so an issue still open when main goes green was not fixed.
flake_decision() {
  fd_runs=$(printf '%s\n' "$1" | tr -d '\r' | grep -o 'Run: [^ ]*/actions/runs/[0-9]*' | sort -u | wc -l | tr -d ' ')
  fd_said=$(printf '%s\n' "$1" | tr -d '\r' | grep -c '^Flake: ')
  if [ "$fd_runs" = 1 ] && [ "$fd_said" = 0 ]; then echo yes; else echo no; fi
}

# flake_note TEXT URL: the comment recording a flake, naming each test the red
# run failed (read from TEXT's "Failed test:" lines), one "Flaky test:" line
# each; the audit counts those lines.
flake_note() {
  printf 'Flake: main went green on the very next run (%s) with no fix, so nothing was wrong with either change.\n' "$2"
  fn_names=$(printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^Failed test: //p' | sort -u)
  if [ -n "$fn_names" ]; then printf '%s\n' "$fn_names" | while IFS= read -r fn_t; do printf 'Flaky test: %s\n' "$fn_t"; done
  else printf 'Flaky test: not named, since the red run kept no failed test name\n'; fi
}

# flaky_report TEXT: the tests TEXT (the comments of the red-main issues closed
# in the last week) names as flaky more than once, one plain line each.
flaky_report() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^Flaky test: //p' | grep -v '^not named' | sort | uniq -c | awk '$1 > 1 { n = $1; sub(/^ *[0-9]+ /, ""); printf "%s flaked %d times in the last week\n", $0, n }'
}
