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
# On only when the repository variable QUEUE_PUBLISH_STATE is "issue" or
# "service" (the state goes to the SipNShip dashboard instead, spec 006)
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
case "$switch" in issue|service) ;; *) [ "$print_only" = yes ] || exit 0 ;; esac
base=${QUEUE_BASE:-main}
now_epoch=$(date +%s)
# Once a minute at most, unless the mode ended (idle) or --print.
if [ "$print_only" = no ] && [ "$mode" != idle ] && [ -f "$flaky_dir/published.at" ]; then
  last=$(cat "$flaky_dir/published.at" 2>/dev/null || echo 0)
  # A moment held back is marked, so the queue's next look sends it.
  if [ $((now_epoch - last)) -lt 60 ]; then printf '%s\n' "$now_epoch" > "$flaky_dir/publish.pending"; exit 0; fi
fi
[ "$print_only" = yes ] || : > "$flaky_dir/publish.pending"

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
# A rush (merge-queue.sh's rush_tick): the list, the paused, the machines.
rush_list=$(tr -d '\r' < "$flaky_dir/rush.list" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
rush_paused_pr() { awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit !f }' "$flaky_dir/rush.paused" 2>/dev/null; }
rush_tsv=""
if [ -n "$rush_list" ]; then
  rush_tsv=$(for rl in $rush_list; do printf 'rush\t%s\n' "$rl"; done
    awk -F'\t' 'NF >= 2 && !seen[$1]++ { printf "paused\t%s\n", $1 }' "$flaky_dir/rush.paused" 2>/dev/null
    awk -F'\t' 'NF >= 2 { printf "machine\t%s\t%s\t%s\n", $1, $2, $3 }' "$flaky_dir/rush.machines" 2>/dev/null)
fi
open_tsv=$(printf '%s\n' "$rows" | sed '/^$/d' | while IFS="$tab" read -r n d mw roll b; do
  [ -n "$n" ] && [ "$b" = "$base" ] || continue
  t=$(printf '%s\n' "$titles" | awk -F'\t' -v n="$n" '$1 == n { print $2; exit }')
  labels=$(printf '%s\n' "$titles" | awk -F'\t' -v n="$n" '$1 == n { print $3; exit }')
  body=$(printf '%s\n' "$titles" | awk -F'\t' -v n="$n" '$1 == n { print $4; exit }')
  case "$body" in *"<!-- merge-queue:batch -->"*|*"<!-- merge-queue:rush -->"*|"One integration run for the pull requests below"*) continue ;; esac
  held=$(held_reason "$(printf '%s' "$labels" | tr ',' '\n')" "$(printf '%s' "$body" | sed 's/ | /\
/g')")
  if [ "$d" = true ]; then s=draft; say="a draft, not queued"
  elif [ -n "$rush_list" ] && rush_paused_pr "$n"; then s=paused; say=$RUSH_PAUSED_SAY
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
# The batch the queue is building or testing now, from its own batch.state
# (written at each change of shape): members in order with titles, the
# anchor, its pull request and the run it waits on, the runner.
bstate=$(tr -d '\r' < "$flaky_dir/batch.state" 2>/dev/null)
if printf '%s\n' "$bstate" | grep -q '^member	'; then
  bs_pr=$(printf '%s\n' "$bstate" | awk -F'\t' '$1 == "pr" { v = $2 } END { print v }')
  bs_run=$(printf '%s\n' "$bstate" | awk -F'\t' '$1 == "run" { v = $2 } END { print v }')
  bdone=""; btotal=""; brunner=""; bmin=""
  if [ -n "$bs_run" ]; then
    prog=$(gh api "repos/{owner}/{repo}/actions/runs/$bs_run/jobs?per_page=100" --jq '"\([.jobs[] | select(.status == "completed")] | length)\t\(.jobs | length)\t\([.jobs[] | select(.status == "in_progress") | .runner_name // empty] | first // "")"' 2>/dev/null | tr -d '\r')
    bdone=$(printf '%s' "$prog" | cut -f1); btotal=$(printf '%s' "$prog" | cut -f2); brunner=$(printf '%s' "$prog" | cut -f3)
    [ "${btotal:-0}" -gt 0 ] 2>/dev/null && bmin=$(( (btotal - bdone) * ${QUEUE_JOB_MINUTES:-4} ))
  fi
  batch_tsv=$(batch_from_state "$bstate" "$bdone" "$btotal" "$bmin" "$brunner")
  [ -n "$bs_pr" ] && batch_row=""
fi
if [ -z "$batch_tsv" ] && [ -n "$batch_row" ]; then
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
# The clashes file: "leftOut\twith\twith's title\tfiles\twhy" per line (an
# older queue wrote "leftOut with"). Fields are cut, never read with a
# tab IFS: read collapses empty tab fields, and a clash once published
# its told flag where the file's name belongs.
clashes_tsv=$(tr -d '\r' < "$flaky_dir/clashes" 2>/dev/null | awk -F'\t' 'NF >= 2 { printf "%s\t%s\t%s\t%s\t%s\tyes\n", $1, $2, $3, $4, $5; next } { split($0, a, " "); if (a[2] != "") printf "%s\t%s\t\t\t\tyes\n", a[1], a[2] }')
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
# The stop line a drain left (merge-queue.sh), said while the queue is idle.
stopped_line=""; [ "$mode" = idle ] && stopped_line=$(head -n 1 "$flaky_dir/stopped" 2>/dev/null | tr -d '\r')
say=$(publish_say "$open_tsv" "$batch_tsv" "$building" "$clashes_tsv" "$attention_tsv" "$runners_tsv" "$deploy_line" "$mode" "$paused_until" "$stopped_line")
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
json=$(publish_json "$open_tsv" "$batch_tsv" "$building" "$clashes_tsv" "$landed_tsv" "$runners_tsv" "$attention_tsv" "$(printf '%s\t%s' "$main_sha" "$main_state")" "$deploy_line" "$mode" "$paused_until" "$checking" "$say" "$now_iso" "$rush_tsv")

# 5. Only a change worth a write: the time stamp and the two numbers that
# tick with time (how long a queued run has waited, a batch's minutes left)
# are left out of the signature, or an idle queue would rewrite every minute.
if [ "$print_only" = no ]; then
  sig=$(printf '%s' "$(publish_body "$say" "$open_tsv" "$batch_tsv" "$landed_tsv" "$json" no)" | sed 's/"updatedAt":"[^"]*"//; s/"longestWaitMinutes":[0-9a-z]*//; s/"minutesLeft":[0-9a-z]*//' | git hash-object --stdin 2>/dev/null)
  if [ -f "$flaky_dir/published.sig" ] && [ "$(cat "$flaky_dir/published.sig")" = "$sig" ]; then exit 0; fi
fi

# 6. Under service: the state goes to the repository's SipNShip dashboard,
# with the queue's wait lines. The token is SIPNSHIP_REPO_TOKEN in CI, or
# this machine's (npx sipnship connect --repo). With no token, or after an
# hour of failed sends, the issue is written as well. One request, three
# seconds at most; only the status is read, and never stops a merge.
write_issue=yes; moved_note=""
if [ "$switch" = service ] && [ "$print_only" = no ]; then
  sn_token=${SIPNSHIP_REPO_TOKEN:-}; sn_id=${SIPNSHIP_REPO_ID:-}
  if [ -z "$sn_token" ] && command -v node >/dev/null 2>&1; then
    sn_repo=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
    sn_pair=$(node -e '
      const fs = require("fs"), path = require("path"), os = require("os");
      const home = process.env.SIPNSHIP_HOME || path.join(os.homedir(), ".sipnship");
      try {
        const repos = JSON.parse(fs.readFileSync(path.join(home, "tokens.json"), "utf8")).repos || {};
        for (const [id, e] of Object.entries(repos)) if (e && String(e.fullName).toLowerCase() === process.argv[1].toLowerCase()) { process.stdout.write(id + "\t" + e.token); break; }
      } catch {}' "$sn_repo" 2>/dev/null)
    if [ -n "$sn_pair" ]; then sn_id=${sn_pair%%	*}; sn_token=${sn_pair#*	}; fi
  fi
  if [ -n "$sn_token" ] && [ -z "$sn_id" ]; then
    sn_id=$(cat "$flaky_dir/repo.id" 2>/dev/null)
    [ -n "$sn_id" ] || { sn_id=$(gh api "repos/{owner}/{repo}" --jq .id 2>/dev/null | tr -d '\r'); [ -n "$sn_id" ] && printf '%s\n' "$sn_id" > "$flaky_dir/repo.id"; }
  fi
  if [ -z "$sn_token" ] || [ -z "$sn_id" ] || ! command -v curl >/dev/null 2>&1; then
    if [ ! -f "$flaky_dir/service.no-token.said" ]; then
      echo "QUEUE_PUBLISH_STATE is service, but this machine is not connected to SipNShip, so the queue writes its issue as before. Run npx sipnship connect --repo, or set SIPNSHIP_REPO_TOKEN in CI."
      : > "$flaky_dir/service.no-token.said"
    fi
  else
    service_body "$json" "$(service_waits_json "$(cat "$flaky_dir/waits.tsv" 2>/dev/null)" $((now_epoch - 7 * 86400)))" > "$flaky_dir/service.body"
    if [ "$(wc -c < "$flaky_dir/service.body" | tr -d ' ')" -gt 65536 ]; then sn_status=413
    else
      sn_post() { printf 'Authorization: Bearer %s\n' "$sn_token" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H @- -H 'content-type: application/json' --data-binary @"$flaky_dir/service.body" "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$sn_id/queue"; }
      sn_status=$(service_send sn_post)
    fi
    sn_outcome=$(service_outcome "$sn_status")
    case "$sn_outcome" in
      ok)
        write_issue=no
        printf '' > "$flaky_dir/service.failing-since"
        printf '' > "$flaky_dir/service.said"
        # The issue says once where the picture now lives.
        if [ ! -f "$flaky_dir/service.moved" ]; then
          write_issue=yes; : > "$flaky_dir/service.moved"
          moved_note="The merge queue's picture now lives on the SipNShip dashboard, ${SIPNSHIP_URL:-https://sipnship.dev}/, and this issue is no longer kept current."
        fi ;;
      rate_limited) write_issue=no ;;
      *)
        since=$(cat "$flaky_dir/service.failing-since" 2>/dev/null | tr -d '\r')
        [ -n "$since" ] || { since=$now_epoch; printf '%s\n' "$since" > "$flaky_dir/service.failing-since"; }
        if [ "$(cat "$flaky_dir/service.said" 2>/dev/null)" != "$sn_outcome" ]; then
          service_say "$sn_outcome" "$sn_status"; echo
          printf '%s' "$sn_outcome" > "$flaky_dir/service.said"
        fi
        write_issue=$(service_issue_too "$since" "$now_epoch") ;;
    esac
  fi
fi
if [ "$write_issue" = no ]; then
  # A failed send keeps no signature, so the next run sends the latest state again.
  case "${sn_outcome:-}" in ok|rate_limited) printf '%s\n' "$sig" > "$flaky_dir/published.sig" ;; esac
  printf '%s\n' "$now_epoch" > "$flaky_dir/published.at"
  exit 0
fi

# 7. The issue: found by title and label, created when missing.
issue=$(gh api "repos/{owner}/{repo}/issues?labels=queue&state=all&per_page=20" --jq '[.[] | select(.title == "Merge queue")] | .[0] | "\(.number)\t\(.state)"' 2>/dev/null | tr -d '\r')
first=no
if [ -z "$issue" ] || [ "$issue" = "null	null" ]; then first=yes; fi
body=$(publish_body "$say" "$open_tsv" "$batch_tsv" "$landed_tsv" "$json" "$first")
if [ "$print_only" = yes ]; then printf '%s\n' "$body"; exit 0; fi
[ -n "$moved_note" ] && body="$moved_note

$body"
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
