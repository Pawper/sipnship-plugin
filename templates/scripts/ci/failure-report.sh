#!/bin/sh
# What a failing CI job says about itself, and what the report job says.
#   sh scripts/ci/failure-report.sh job [LOG]   in a failing job: a job
#       summary and an annotation naming the failed step with LOG's last
#       lines. It never cancels the run: that would mark this job cancelled
#       and hide the failure. GitHub has no call to cancel one job, so a
#       failed test part stops its sibling parts through the matrix's
#       fail-fast, and the other jobs finish.
#   sh scripts/ci/failure-report.sh run         in the report job: each
#       failed job, its step and its lines, in the job summary, and the
#       jobs cancelled because of it
# Needs GH_TOKEN and actions: read (checks: read for "run").
here=$(dirname "$0")
. "$here/failure-lib.sh"
api="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs"
jobs=$(gh api "$api" --paginate --jq '.jobs[] | [.id, .name, .status, (.conclusion // ""), (.runner_name // ""), ([.steps[]? | select(.conclusion == "failure") | .name][0] // "")] | @tsv') || jobs=
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
case "$1" in
  job)
    me=$(own_job "$jobs" "$RUNNER_NAME")
    name=$(printf '%s' "$me" | cut -f2)
    step=$(printf '%s' "$me" | cut -f6)
    lines=
    [ -z "$2" ] || [ ! -f "$2" ] || lines=$(tail -n 30 "$2")
    failure_summary "${name:-${GITHUB_JOB:-this job}}" "$step" "$lines" >> "$summary"
    failure_annotation "${name:-${GITHUB_JOB:-this job}}" "$step" "$lines" ;;
  run)
    lines=$(printf '%s\n' "$jobs" | awk -F '\t' '$4 == "failure" { print $1 "\t" $2 }' | while IFS="	" read -r id name; do
      gh api "repos/$GITHUB_REPOSITORY/check-runs/$id/annotations" --jq '.[] | select((.title // "") | test(" failed at ")) | .message' 2>/dev/null \
        | awk -v n="$name" '{ print n "\t" $0 }'
    done)
    run_report "$jobs" "$lines" >> "$summary" ;;
  *) echo "usage: failure-report.sh job [LOG] | run" >&2; exit 2 ;;
esac
