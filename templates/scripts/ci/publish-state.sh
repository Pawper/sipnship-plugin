#!/bin/sh
# Publish the merge queue's state to the repository's "Merge queue" issue
# (spec 001): three plain sentences for a person, the open pull requests,
# the batch, what landed lately, and a JSON block for agents. The queue
# calls this as it goes; it also runs on its own.
#
# Usage: sh scripts/ci/publish-state.sh [--mode MODE] [--open FILE] [--print]
#   --mode   idle draining serial batch paused (default idle)
#   --open   a file of the drain's rows "number\tdraft\tmergeable\trollup\tbase",
#            so a running drain is not read twice; without it the open pull
#            requests are read here
#   --print  print the body; write nothing
# On only when the repository variable QUEUE_PUBLISH_STATE is "issue"
# (or the environment sets it); otherwise it exits quietly. Writes only
# when the body changed, and never more often than once a minute. A write
# that fails is said once and never stops a merge.
here=$(dirname "$0")
. "$here/publish-lib.sh"
. "$here/batch-lib.sh"
mode=idle; open_file=""; print_only=no
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) shift; mode=$1 ;;
    --open) shift; open_file=$1 ;;
    --print) print_only=yes ;;
  esac
  shift
done
command -v gh >/dev/null 2>&1 || exit 0
flaky_dir=${QUEUE_DIR:-.scratch/queue}; mkdir -p "$flaky_dir" 2>/dev/null || true
tab=$(printf '\t')

switch=${QUEUE_PUBLISH_STATE:-}
if [ -z "$switch" ]; then
  switch=$(gh api "repos/{owner}/{repo}/actions/variables/QUEUE_PUBLISH_STATE" --jq .value 2>/dev/null || echo off)
fi
if [ "$switch" != issue ] && [ "$print_only" = no ]; then exit 0; fi
base=${QUEUE_BASE:-main}
now_epoch=$(date +%s)
# Once a minute at most, unless the mode ended (idle) or --print.
if [ "$print_only" = no ] && [ "$mode" != idle ] && [ -f "$flaky_dir/published.at" ]; then
  last=$(cat "$flaky_dir/published.at" 2>/dev/null || echo 0)
  if [ $((now_epoch - last)) -lt 60 ]; then exit 0; fi
fi

# 1. Open pull requests, with a state and a sentence each.
if [ -n "$open_file" ] && [ -f "$open_file" ]; then rows=$(cat "$open_file"); else
  rows=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, (.draft | tostring), .head.sha, .base.ref] | @tsv' 2>/dev/null | tr -d '\r' | while IFS="$tab" read -r n d sha b; do
    [ -n "$n" ] || continue
    roll=$(rest_rollup_named "$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)"' 2>/dev/null)" "${QUEUE_SUMMARY_CHECK:-CI passed}")
    mw=$(mergeable_word "$(gh api "repos/{owner}/{repo}/pulls/$n" --jq '.mergeable_state // ""' 2>/dev/null)")
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$d" "$mw" "$roll" "$b"
  done)
fi
titles=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))\t\((.body // "") | gsub("[\r\n]+"; " | "))"' 2>/dev/null | tr -d '\r')
batch_pr=""; batch_members=""
open_tsv=$(printf '%s\n' "$rows" | sed '/^$/d' | while IFS="$tab" read -r n d mw roll b; do
  [ -n "$n" ] && [ "$b" = "$base" ] || continue
  t=$(printf '%s\n' "$titles" | awk -F'\t' -v n="$n" '$1 == n { print $2; exit }')
  labels=$(printf '%s\n' "$titles" | awk -F'\t' -v n="$n" '$1 == n { print $3; exit }')
  body=$(printf '%s\n' "$titles" | awk -F'\t' -v n="$n" '$1 == n { print $4; exit }')
  case "$body" in *"<!-- merge-queue:batch -->"*|"One integration run for the pull requests below"*) continue ;; esac
  held=$(held_reason "$(printf '%s' "$labels" | tr ',' '\n')" "$(printf '%s' "$body" | sed 's/ | /\
/g')")
  if [ "$d" = true ]; then s=draft; say="a draft, not queued"
  elif [ -n "$held" ]; then s=held; say="held on purpose ($held); it waits until the hold is removed"
  elif [ "$mw" = CONFLICTING ]; then s=conflicts-with-main; say="conflicts with main; its owner merges main in and fixes it before the queue takes it"
  else
    case "$roll" in
      green) s=green; say="green and waiting to merge" ;;
      red) s=red; say="red; the queue re-runs its failed jobs once, then names it here" ;;
      *) s=waiting; say="still running CI" ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\n' "$n" "$t" "$s" "$say"
done)
# The open batch pull request, if any.
batch_row=$(printf '%s\n' "$titles" | awk -F'\t' '$4 ~ /<!-- merge-queue:batch -->/ || $4 ~ /^One integration run for the pull requests below/ { print $1; exit }')
batch_tsv=""
if [ -n "$batch_row" ]; then
  bbody=$(gh api "repos/{owner}/{repo}/pulls/$batch_row" --jq '.body // ""' 2>/dev/null)
  members=$(batch_members "$bbody" | tr '\n' ' ' | sed 's/ $//')
  anchor=$(printf '%s\n' $members | head -n 1)
  bsha=$(gh api "repos/{owner}/{repo}/pulls/$batch_row" --jq .head.sha 2>/dev/null)
  prog=$(gh api "repos/{owner}/{repo}/commits/$bsha/check-runs?per_page=100" --jq '[.check_runs[] | .status] | "\(map(select(. == "completed")) | length)\t\(length)"' 2>/dev/null | tr -d '\r')
  bdone=${prog%%	*}; btotal=${prog#*	}
  bmin=""; [ "${btotal:-0}" -gt 0 ] 2>/dev/null && bmin=$(( (btotal - bdone) * ${QUEUE_JOB_MINUTES:-4} ))
  batch_tsv=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$batch_row" "$members" "$anchor" "${bdone:-0}" "${btotal:-0}" "$bmin")
fi

# 2. What the queue keeps locally.
now_line=$(head -n 1 "$flaky_dir/now" 2>/dev/null | tr -d '\r')
checking=""; building=""
case "$now_line" in
  checking\ *) checking=${now_line#checking } ;;
  building\ *) building=${now_line#building } ;;
esac
clashes_tsv=$(awk 'NF >= 2 { printf "%s\t%s\t\tyes\n", $1, $2 }' "$flaky_dir/clashes" 2>/dev/null)
attention_tsv=$(awk -F'\t' 'NF >= 2' "$flaky_dir/attention.tsv" 2>/dev/null)
paused_until=""
if [ "$mode" = idle ]; then
  pu=$(gh api "repos/{owner}/{repo}/actions/variables/QUEUE_PAUSED_UNTIL" --jq .value 2>/dev/null || true)
  if [ -n "$pu" ] && [ "$(date -u -d "$pu" +%s 2>/dev/null || echo 0)" -gt "$now_epoch" ]; then mode=paused; paused_until=$pu; fi
fi

# 3. Main, landed, runners, deploy.
# Main and what landed are read from GitHub, not the local origin/main ref:
# right after the queue merges through the API that ref is stale until a
# fetch, and the first end-of-drain write once listed everything but the
# pull request that had just landed. It also lets this run from any
# checkout.
main_sha=$(gh api "repos/{owner}/{repo}/commits/$base" --jq '.sha[0:7]' 2>/dev/null | tr -d '\r')
[ -n "$main_sha" ] || main_sha=$(git rev-parse "origin/$base" 2>/dev/null | cut -c1-7)
main_run=$(gh api "repos/{owner}/{repo}/actions/workflows/${QUEUE_CI_WORKFLOW:-ci.yml}/runs?branch=$base&event=push&per_page=1" --jq '.workflow_runs[0] | "\(.head_sha[0:7])\t\(.status)\t\(.conclusion // "")"' 2>/dev/null | tr -d '\r')
main_state=unknown
if [ -n "$main_run" ]; then
  mr_sha=${main_run%%	*}; mr_rest=${main_run#*	}; mr_status=${mr_rest%%	*}; mr_conc=${mr_rest#*	}
  if [ "$mr_sha" != "$main_sha" ] || [ "$mr_status" != completed ]; then main_state=pending; elif [ "$mr_conc" = success ]; then main_state=green; else main_state=red; fi
fi
landed_src=$(gh api "repos/{owner}/{repo}/commits?sha=$base&per_page=40" --jq '.[] | "\(.commit.message | split("\n")[0])\t\(.commit.committer.date)"' 2>/dev/null | tr -d '\r')
[ -n "$landed_src" ] || landed_src=$(git log "origin/$base" -n 40 --format='%s%x09%cI' 2>/dev/null)
landed_tsv=$(printf '%s\n' "$landed_src" | awk -F'\t' '{ if (match($1, /\(#[0-9]+\)/)) { n = substr($1, RSTART + 2, RLENGTH - 3); how = ($1 ~ /\[batch/ || $1 ~ /^batch PR/ || $1 ~ /merged into main/) ? "batch" : "serial"; t = $1; sub(/ \(#[0-9]+\).*$/, "", t); if (!(n in seen)) { seen[n] = 1; printf "%s\t%s\t%s\t%s\n", n, t, how, $2; c++ } } if (c >= 10) exit }')
runners_tsv=""
rr=$(gh api "repos/{owner}/{repo}/actions/runners" --jq '"\([.runners[] | select(.status == "online")] | length)\t\([.runners[] | select(.busy)] | length)"' 2>/dev/null | tr -d '\r')
if [ -n "$rr" ]; then
  queued=$(gh api "repos/{owner}/{repo}/actions/runs?status=queued&per_page=50" --jq '.workflow_runs | length' 2>/dev/null || echo 0)
  longest=$(gh api "repos/{owner}/{repo}/actions/runs?status=queued&per_page=50" --jq --arg now "$now_epoch" '[.workflow_runs[] | (($now | tonumber) - (.created_at | fromdate)) / 60 | floor] | max // 0' 2>/dev/null || echo 0)
  runners_tsv=$(printf '%s\t%s\t%s' "$rr" "${queued:-0}" "${longest:-0}")
fi
deploy_line=""; [ -f .claude/deploy.json ] && [ -f "$here/deploy-gate.sh" ] && deploy_line=$(sh "$here/deploy-gate.sh" --last "$base" 2>/dev/null | head -n 1)

# 4. Compose.
say=$(publish_say "$open_tsv" "$batch_tsv" "$building" "$clashes_tsv" "$attention_tsv" "$runners_tsv" "$deploy_line" "$mode" "$paused_until")
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
json=$(publish_json "$open_tsv" "$batch_tsv" "$building" "$clashes_tsv" "$landed_tsv" "$runners_tsv" "$attention_tsv" "$(printf '%s\t%s' "$main_sha" "$main_state")" "$deploy_line" "$mode" "$paused_until" "$checking" "$say" "$now_iso")

# 5. The issue: found by title and label, created when missing.
issue=$(gh api "repos/{owner}/{repo}/issues?labels=queue&state=all&per_page=20" --jq '[.[] | select(.title == "Merge queue")] | .[0] | "\(.number)\t\(.state)"' 2>/dev/null | tr -d '\r')
first=no
if [ -z "$issue" ] || [ "$issue" = "null	null" ]; then first=yes; fi
body=$(publish_body "$say" "$open_tsv" "$batch_tsv" "$landed_tsv" "$json" "$first")
if [ "$print_only" = yes ]; then printf '%s\n' "$body"; exit 0; fi
# Only when the body changed, apart from the time stamp.
# Only a change worth a write: the time stamp and the two numbers that tick
# with time (how long a queued run has waited, a batch's minutes left) are
# left out of the signature, or an idle queue would rewrite every minute.
sig=$(printf '%s' "$body" | sed 's/"updatedAt":"[^"]*"//; s/"longestWaitMinutes":[0-9a-z]*//; s/"minutesLeft":[0-9a-z]*//' | git hash-object --stdin 2>/dev/null)
if [ -f "$flaky_dir/published.sig" ] && [ "$(cat "$flaky_dir/published.sig")" = "$sig" ]; then exit 0; fi
printf '%s' "$body" > "$flaky_dir/published.body"
if [ "$first" = yes ]; then
  num=$(gh api -X POST "repos/{owner}/{repo}/issues" -f title="Merge queue" -F body=@"$flaky_dir/published.body" -f "labels[]=queue" -f "labels[]=$(state_label parked "$(project_label_form)")" --jq .number 2>"$flaky_dir/publish.err") || { echo "Could not create the Merge queue issue: $(head -n 1 "$flaky_dir/publish.err")" >&2; exit 0; }
  echo "Created the Merge queue issue #$num; pin it from its page so it stays at the top."
else
  num=${issue%%	*}; st=${issue#*	}
  if [ "$st" = closed ]; then
    gh api -X PATCH "repos/{owner}/{repo}/issues/$num" -f state=open >/dev/null 2>&1 && echo "Reopened the Merge queue issue #$num, which the queue keeps."
  fi
  gh api -X PATCH "repos/{owner}/{repo}/issues/$num" -F body=@"$flaky_dir/published.body" >/dev/null 2>"$flaky_dir/publish.err" || { echo "Could not update the Merge queue issue #$num: $(head -n 1 "$flaky_dir/publish.err")" >&2; exit 0; }
fi
printf '%s\n' "$sig" > "$flaky_dir/published.sig"
printf '%s\n' "$now_epoch" > "$flaky_dir/published.at"
exit 0
