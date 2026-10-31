#!/bin/sh
# Main's full gate after a quiet hour (gate-lib.sh says why).
#   sh scripts/ci/gate.sh decide [EVENT]  in the scheduled run's "gate" job:
#       prints "run" or "skip: <why>"; GATE_QUIET_MINUTES is the quiet time
#   sh scripts/ci/gate.sh last            the last gate that ran its tests:
#       "head-sha<TAB>conclusion<TAB>created-epoch", or nothing
# The last gated head is read from GitHub, never kept in a file: the
# newest completed scheduled runs of ci.yml, and of those the first whose
# tests job ran. Needs GH_TOKEN; REST only.
here=$(dirname "$0")
. "$here/gate-lib.sh"
wf=${QUEUE_CI_WORKFLOW:-ci.yml}
to_epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null; }
runs_tsv() {
  gh api "repos/{owner}/{repo}/actions/workflows/$wf/runs?branch=main&event=schedule&status=completed&per_page=24" \
    --jq '.workflow_runs[] | [.id, .head_sha, (.conclusion // ""), .created_at] | @tsv' 2>/dev/null | tr -d '\r' \
    | while IFS="	" read -r id sha conc at; do
        ran=$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100" --jq '[.jobs[] | select(.name | startswith("tests")) | select(.conclusion != "skipped")] | if length > 0 then "yes" else "no" end' 2>/dev/null | tr -d '\r')
        printf '%s\t%s\t%s\t%s\n' "$sha" "$conc" "$(to_epoch "$at")" "${ran:-no}"
        if [ "$ran" = yes ]; then [ "$conc" = cancelled ] || break; fi
      done
}
case "$1" in
  last) last_gated "$(runs_tsv)" ;;
  decide)
    head=$(gh api "repos/{owner}/{repo}/commits/main" --jq '.sha + "\t" + .commit.committer.date' 2>/dev/null | tr -d '\r')
    [ -n "$head" ] || { echo "skip: main cannot be read"; exit 0; }
    gated=$(last_gated "$(runs_tsv)")
    gate_decide "${head%%	*}" "$(printf '%s' "$gated" | cut -f1)" "$(to_epoch "${head#*	}")" "$(date +%s)" "${GATE_QUIET_MINUTES:-60}" "${2:-}" ;;
  *) echo "usage: gate.sh decide [EVENT] | last" >&2; exit 2 ;;
esac
