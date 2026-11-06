#!/bin/sh
# console-failures.sh LOG: print, from a node test run's TAP log, what a person
# needs to name the failing case: every "not ok" entry whole (its name, the
# assertion's message, expected and actual, the exit code of a test file that
# ended badly), and any text a test file wrote to its error output, which the
# reporter carries as "# " comment lines. Stack frames inside node itself are
# left out. At most 120 lines, so a log stays readable.
awk '
  /^# (Subtest:|tests |suites |pass |fail |cancelled |skipped |todo |duration_ms)/ { inblock = 0; next }
  /^# / { print; n++; next }
  /^(not ok|ok) / { inblock = ($1 == "not"); if (inblock) { print; n++ } next }
  inblock && /^  \.\.\.$/ { print; n++; inblock = 0; next }
  inblock && /^    at .*node:internal/ { next }
  inblock { print; n++ }
  n >= 120 { exit }
' "$1" | tr -d '\r' | head -n 120
