#!/bin/sh
# Run one check and keep what it printed, so a failing run can say why.
#   sh scripts/ci/check-log.sh COMMAND [ARGS...]
# The output goes to the job's log as usual and also to
# $RUNNER_TEMP/check.log, which each check overwrites: the checks job stops
# at its first failure, so the file holds the failed check's own lines.
# "Say what failed" (failure-report.sh job) reads them into the annotation
# and the job summary, which the report job and the merge queue then read
# back even though the run was cancelled before they started. The exit code
# is the check's own.
log="${RUNNER_TEMP:-.scratch}/check.log"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
"$@" > "$log" 2>&1
code=$?
cat "$log"
exit "$code"
