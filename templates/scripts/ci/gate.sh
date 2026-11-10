#!/bin/sh
# Main's full gate after a quiet hour (gate-lib.sh says why).
#   sh scripts/ci/gate.sh decide [EVENT]  in the scheduled run's "gate" job:
#       prints "run" or "skip: <why>"; GATE_QUIET_MINUTES is the quiet time
#   sh scripts/ci/gate.sh last            the last gate that ran its tests:
#       "head-sha<TAB>conclusion<TAB>created-epoch", or nothing
#   sh scripts/ci/gate.sh why             "nostart" when the last gate was red with no test job
#       started (GitHub did not start the jobs); nothing otherwise
#   sh scripts/ci/gate.sh early-red       the line for a gate that failed before its
#       tests started (nothing when none did); early-red-count: how many in a row
#   sh scripts/ci/gate.sh failing         the last gate's failing tests, when it
#       failed: "part: test" per line, at most five, read from the failed
#       jobs' annotations; nothing when it passed or named none
# The last gated head is read from GitHub, never kept in a file: the
# newest completed scheduled runs of ci.yml, and of those the first whose
# tests job ran. Needs GH_TOKEN; REST only.
here=$(dirname "$0")
. "$here/gate-lib.sh"
wf=${QUEUE_CI_WORKFLOW:-ci.yml}
to_epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null; }
# runs_tsv [HEAD]: with HEAD, the scan ends at the first run on another head
# (the decision only asks whether HEAD was gated), so it costs one call a run
# on main's own head, never one for every run of the day.
runs_tsv() {
  only=${1:-}
  gh api "repos/{owner}/{repo}/actions/workflows/$wf/runs?branch=main&event=schedule&status=completed&per_page=24" \
    --jq '.workflow_runs[] | [.id, .head_sha, (.conclusion // ""), .created_at] | @tsv' 2>/dev/null | tr -d '\r' \
    | while IFS="	" read -r id sha conc at; do
        [ -z "$only" ] || [ "$sha" = "$only" ] || break
        ran=$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100" --jq '[.jobs[] | select(.name | startswith("tests")) | select(.conclusion != "skipped")] | if length > 0 then "yes" else "no" end' 2>/dev/null | tr -d '\r')
        printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$conc" "$(to_epoch "$at")" "${ran:-no}" "$id"
        if [ "$ran" = yes ]; then [ "$conc" = cancelled ] || break; fi
      done
}
case "$1" in
  last) last_gated "$(runs_tsv)" ;;
  why) gate_last_why "$(runs_tsv)" ;;
  early-red) gate_early_red_line "$(runs_tsv)" ;;
  early-red-count) gate_early_red_count "$(runs_tsv)" ;;
  early-red-run) gate_early_red_run "$(runs_tsv)" ;;
  failing)
    runs=$(runs_tsv)
    [ "$(last_gated "$runs" | cut -f2)" = failure ] || exit 0
    run=$(last_gated_run "$runs")
    [ -n "$run" ] || exit 0
    lines=$(gh api "repos/{owner}/{repo}/actions/runs/$run/jobs?per_page=100" --jq '.jobs[] | select(.name | startswith("tests")) | select(.conclusion == "failure") | [.id, .name] | @tsv' 2>/dev/null | tr -d '\r' | while IFS="	" read -r jid jname; do
      gh api "repos/{owner}/{repo}/check-runs/$jid/annotations" --jq '.[] | select((.title // "") | test(" failed at ")) | .message' 2>/dev/null | awk -v n="$jname" '{ print n "	" $0 }'
    done)
    gate_failing_tests "$lines" 5 ;;
  decide)
    head=$(gh api "repos/{owner}/{repo}/commits/main" --jq '.sha + "\t" + .commit.committer.date' 2>/dev/null | tr -d '\r')
    [ -n "$head" ] || { echo "skip: main cannot be read"; exit 0; }
    quiet=${GATE_QUIET_MINUTES:-60}
    # Not due on the quiet time alone: no run is read.
    early=$(gate_skip_early "${head%%	*}" "$(to_epoch "${head#*	}")" "$(date +%s)" "$quiet" "${2:-}")
    [ -z "$early" ] || { echo "$early"; exit 0; }
    gated=$(last_gated_ran "$(runs_tsv "${head%%	*}")")
    gate_decide "${head%%	*}" "$(printf '%s' "$gated" | cut -f1)" "$(to_epoch "${head#*	}")" "$(date +%s)" "$quiet" "${2:-}" ;;
  *) echo "usage: gate.sh decide [EVENT] | last | early-red | early-red-count | failing | why" >&2; exit 2 ;;
esac
