#!/bin/sh
# What a failing CI job says about itself, and what the report job says.
#   sh scripts/ci/failure-report.sh job [LOG]   in a failing job: a job
#       summary and an annotation naming the failed step with LOG's last
#       lines. It never cancels the run. GitHub has no call to cancel one
#       job, so a failed test part stops its sibling parts through the
#       matrix's fail-fast, and the other jobs finish.
#   sh scripts/ci/failure-report.sh cancel      in the checks job, after
#       "job": a failed check means the run cannot merge, so the run is
#       cancelled and its jobs still waiting for a runner leave the line.
#       The cancel marks the checks job cancelled; "job" has already named
#       its failed step, and "run" reports a cancelled job with a failed
#       step as failed.
#   sh scripts/ci/failure-report.sh stopped PART MINUTES [LOG]   in a test
#       part cancelled from outside: says why, as a warning, with how long it
#       had run; "ran out of its minutes" only when it reached MINUTES
#   sh scripts/ci/failure-report.sh verdict     prints failed, stopped or
#       none: stopped is cancelled with nothing failed (a rush or a hold)
#   sh scripts/ci/failure-report.sh run         in the report job: each
#       failed job, its step and its lines, in the job summary, and the
#       jobs cancelled because of it
# Needs GH_TOKEN and actions: read (checks: read for "run", actions: write
# for "cancel").
here=$(dirname "$0")
. "$here/run-lib.sh"
. "$here/failure-lib.sh"
api="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs"
jobs=$(gh api "$api" --paginate --jq '.jobs[] | [.id, .name, .status, (.conclusion // ""), (.runner_name // ""), ([.steps[]? | select(.conclusion == "failure") | .name][0] // ""), (.completed_at // ""), (.started_at // "")] | @tsv') || jobs=
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
case "$1" in
  job)
    me=$(own_job "$jobs" "$RUNNER_NAME")
    name=$(printf '%s' "$me" | cut -f2)
    step=$(printf '%s' "$me" | cut -f6)
    lines=
    slow=
    # The failing tests named anywhere in the log lead the last lines (failure_lines), so a test that printed a lot after it failed is still named.
    [ -z "$2" ] || [ ! -f "$2" ] || { lines=$(failure_lines "$(cat "$2")" "$(tail -n 30 "$2")"); slow=$(slow_say "$(cat "$2")"); }
    failure_summary "${name:-${GITHUB_JOB:-this job}}" "$step" "$lines" "$slow" >> "$summary"
    failure_annotation "${name:-${GITHUB_JOB:-this job}}" "$step" "$lines" "$slow" ;;
  stopped)
    me=$(own_job "$jobs" "$RUNNER_NAME")
    name=$(printf '%s' "$me" | cut -f2)
    began=$(printf '%s' "$me" | cut -f8)
    secs=0
    if [ -n "$began" ]; then
      b=$(date -u -d "$began" +%s 2>/dev/null) && secs=$(( $(date -u +%s) - b ))
    fi
    others=$(failed_others "$(printf '%s\n' "$jobs" | sort -t "$(printf '\t')" -k7,7)" "$name")
    say=$(stopped_say "$2" "$secs" "$3" "$others")
    if [ "$secs" -ge $(( ${3:-180} * 60 )) ]; then
      last=
      [ -z "$4" ] || [ ! -f "$4" ] || last=$(grep '^# ' "$4" 2>/dev/null | tail -n 1)
      echo "::error title=A test part hung::$say The last test it started: ${last#\# }"
    else
      echo "::warning title=A test part was stopped::$say"
    fi ;;
  cancel)
    if gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/cancel" >/dev/null 2>&1; then
      echo "A check failed, so this run cannot merge: cancelled its jobs still waiting for a runner."
    else
      echo "Could not cancel this run (it needs actions: write); its other jobs run to the end."
    fi ;;
  run)
    lines=$(printf '%s\n' "$jobs" | awk -F '\t' '$4 == "failure" || ($4 == "cancelled" && $6 != "") { print $1 "\t" $2 }' | while IFS="	" read -r id name; do
      gh api "repos/$GITHUB_REPOSITORY/check-runs/$id/annotations" --jq '.[] | select((.title // "") | test(" failed at ")) | .message' 2>/dev/null \
        | awk -v n="$name" '{ print n "\t" $0 }'
    done)
    run_report "$(printf '%s\n' "$jobs" | sort -t "$(printf '\t')" -k7,7)" "$lines" >> "$summary" ;;
  verdict) run_verdict "$jobs" ;;
  *) echo "usage: failure-report.sh job [LOG] | stopped PART MINUTES [LOG] | cancel | run | verdict" >&2; exit 2 ;;
esac
