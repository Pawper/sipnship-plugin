#!/bin/sh
# The place job: the first job of a workflow whose builds can run in more
# than one place. It reads the builder's order, the repository's runners and
# whether GitHub will start hosted jobs, and writes, for every job after it,
# where that job runs (rules in queue/rules-place.sh). Run by
# .github/workflows/place.yml; see that file for how a workflow uses it.
#   env: PLACE_JOBS       one line a job: NAME SYSTEM LABELS, LABELS being
#                         its runs-on labels on your machines, comma-separated
#        SIPNSHIP_PLACES  the order (rules-place.sh); SIPNSHIP_PLACE_REFUSED
#        HOSTED_MINUTES   "gone" when GitHub will not start hosted jobs
#        CI_KEEP_RUNNER   "on" when one runner is kept for the batch and main
#        GH_TOKEN         a token that can read the runners (the queue's)
#        GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_EVENT_NAME, GITHUB_HEAD_REF
# Writes the outputs runs-on and where (place_outputs). Two REST calls,
# well under ten seconds. When the runners cannot be read, your machines are
# taken to be up, and the drain's rescue moves a job that then waits.
set -e
here=$(dirname "$0")
. "$here/batch-lib.sh"
order="${SIPNSHIP_PLACES:-order=own} ${SIPNSHIP_PLACE_REFUSED:-}"
kind=$(place_kind "${GITHUB_EVENT_NAME:-}" "${GITHUB_HEAD_REF:-}")
gone=no; [ "${HOSTED_MINUTES:-}" = gone ] && gone=yes
keep=${CI_KEEP_RUNNER:-off}
now=$(date -u +%s)
if runners=$(gh api "repos/{owner}/{repo}/actions/runners?per_page=100" --jq '.runners[] | [.status, (.busy | tostring), ([.labels[].name] | join(","))] | @tsv' 2>/dev/null); then read_ok=yes
else read_ok=no; echo "The runners could not be read; your machines are taken to be up."; fi
queued=$(gh api "repos/{owner}/{repo}/actions/runs?status=queued&per_page=1" --jq .total_count 2>/dev/null | tr -d '\r' || true)
placed=""
words=""
old_ifs=$IFS; IFS='
'
for line in $(printf '%s\n' "${PLACE_JOBS:-}" | tr -d '\r' | sed '/^[[:space:]]*$/d'); do
  IFS=$old_ifs
  set -- $line
  name=$1; system=$2; labels=${3:-self-hosted}
  # With no kept runner, a pull request's jobs take any runner, as today.
  [ "$keep" = on ] || labels=$(printf '%s' "$labels" | tr ',' '\n' | grep -vx pr | paste -sd, -)
  if [ "$read_ok" = yes ]; then facts=$(own_facts "$labels" "$keep" "$runners" "${queued:-0}"); else facts=unknown; fi
  pl=$(place_job "$order" "$system" "$kind" "$labels" "$facts" "$gone" "$now")
  placed=$(printf '%s\n%s\t%s\t%s' "$placed" "$name" "$(printf '%s' "$pl" | cut -f1)" "$(printf '%s' "$pl" | cut -f2)")
  words=$(printf '%s\n- %s: %s' "$words" "$name" "$(place_words "$pl")")
done
IFS=$old_ifs
outs=$(printf '%s\n' "$placed" | place_outputs)
printf 'runs-on=%s\nwhere=%s\n' "$(printf '%s\n' "$outs" | sed -n 1p)" "$(printf '%s\n' "$outs" | sed -n 2p)" >> "${GITHUB_OUTPUT:-/dev/stdout}"
printf '### Where this run builds\n%s\n' "$words" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
printf '%s\n' "$words" | sed '/^$/d'
