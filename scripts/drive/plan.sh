#!/bin/sh
# Gather the project's state and print the proposal the project-drive skill
# would put to a person. This script never acts: it reads, decides, prints.
# The skill posts the proposal and, once approved, pursues it.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/plan.sh" [--dry-run] [--snapshot] [--fast] [--facts FILE]
# --dry-run is accepted and changes nothing: this script is always dry.
# --snapshot also prints the raw facts the proposal was made from.
# --facts FILE reuses facts already fetched by board-now.sh.
# --fast skips the one extra call for the audit issue's latest comment.
#
# The whole board comes from one GraphQL call (hooks/scripts/board-now.sh).
# Reads .claude/project-drive.json when present: runners (an optional cap on
# the agents at once; with none, the runners GitHub lists online and free decide),
# maxAgents (4), maxMinutes (90), queueLogGlob, ownerDecisions, and the
# round's choices drive_settings reads (round-lib.sh): unitsPerRound (2),
# dispatchModel, setAsideAfterReds (2), summaryAt, healthNote.
# Open pull requests are read again over REST (scripts/drive/round-lib.sh,
# overlay_rest), so one that conflicts with main is proposed as merge-main
# and one red too often as set-aside.
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/../../hooks/scripts/session-brief-lib.sh"
. "$here/drive-lib.sh"
. "$here/bundle-lib.sh"
. "$here/round-lib.sh"
. "$here/stale-lib.sh"

show_snapshot=no; fast=no; facts_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) show_snapshot=yes ;;
    --fast) fast=yes ;;
    --facts) shift; facts_file=$1 ;;
  esac
  shift
done

runners=2; runners_cap=0; max_agents=4; max_minutes=90; queue_glob=""; owner_phrases=""
settings=$(drive_settings '{}')
if [ -f .claude/project-drive.json ]; then
  cfg=$(cat .claude/project-drive.json)
  n=$(json_number "$cfg" runners); [ -n "$n" ] && runners_cap=$n
  n=$(json_number "$cfg" maxAgents); [ -n "$n" ] && max_agents=$n
  n=$(json_number "$cfg" maxMinutes); [ -n "$n" ] && max_minutes=$n
  queue_glob=$(json_field "$cfg" queueLogGlob)
  settings=$(drive_settings "$cfg")
  owner_phrases=$(printf '%s' "$cfg" | awk 'BEGIN { RS = "\001" } { i = index($0, "\"ownerDecisions\""); if (!i) exit; s = substr($0, i); j = index(s, "["); k = index(s, "]"); if (!j || !k) exit; print substr(s, j + 1, k - j - 1) }' \
    | tr ',' '\n' | sed 's/^[ \t"]*//;s/[ \t"]*$//' | sed '/^$/d')
fi

if [ -n "$facts_file" ] && [ -f "$facts_file" ]; then
  facts=$(cat "$facts_file")
else
  facts=$(sh "$here/../../hooks/scripts/board-now.sh" 2>"${TMPDIR:-/tmp}/board-now.$$.err") || facts=""
fi
if [ -z "$facts" ]; then
  if [ "$(gh_refusal "$(cat "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null)")" = yes ]; then
    echo "GitHub refused the board read for its rate limit (GraphQL's secondary limit; REST may still be fine); try the round again in a few minutes, and keep one queue and one drive at a time."
    echo "stop: rate-limited"
  else
    echo "gh is not available or not signed in; the round cannot read the project."
    echo "stop: unavailable"
  fi
  rm -f "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null
  exit 0
fi
rm -f "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null

rules=""
[ -f scripts/ci/classes.txt ] && [ -f scripts/ci/lib.sh ] && rules=$(cat scripts/ci/classes.txt)
tab=$(printf '\t')
tmp=$(mktemp)

# Turn the facts into a snapshot, with no further network calls.
printf '%s\n' "$facts" | while IFS="$tab" read -r kind num title a b c d e; do
  case "$kind" in
    pr)
      case "$a" in SUCCESS) ci=green ;; FAILURE|ERROR) ci=red ;; *) ci=pending ;; esac
      merge=$(printf '%s' "$b" | tr 'A-Z' 'a-z')
      class=app
      if [ -n "$rules" ]; then
        cls=$(sh -c '. scripts/ci/lib.sh; classify_paths "$1" "$2"' sh "$(printf '%s' "$d" | tr ',' '\n')" "$rules")
        case " $cls " in *" app "*|*" other "*|*" tests "*|*" data "*) class=app ;; *) class=other ;; esac
      fi
      printf 'pr\t%s\t%s\t%s\t%s\t%s\n' "$num" "$title" "$ci" "$merge" "$class"
      ;;
    issue)
      state=$(state_of_labels "$a")
      case ",$a," in *",ci-red,"*) printf 'red\t%s\n' "$num" ;; esac
      case "$state" in
        ready)
          owner=no
          # Title and the start of the body, both from the one call.
          if [ -n "$owner_phrases" ] && [ -n "$(owner_decision_hit "$title $c" "$owner_phrases")" ]; then owner=yes; fi
          printf 'issue\t%s\t%s\tready\t%s\n' "$num" "$title" "$owner" ;;
        in-progress|waiting-on-owner|blocked)
          printf 'issue\t%s\t%s\t%s\tno\n' "$num" "$title" "$state" ;;
      esac
      ;;
  esac
done >> "$tmp"

# The audit issue's latest comment: one extra call, skipped with --fast.
if [ "$fast" = no ]; then
  audit_issue=$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "issue" && ("," $4 ",") ~ /,audit,/ { print $2; exit }')
  if [ -n "$audit_issue" ]; then
    last=$(gh issue view "$audit_issue" --json comments --jq '.comments[-1].body // ""' 2>/dev/null | tr '\n' ' ' | cut -c1-200)
    [ -n "$last" ] && printf 'audit\t%s\n' "$last" >> "$tmp"
  fi
fi

queue_state=none
if [ -n "$queue_glob" ]; then
  newest=""; newest_m=0
  for f in $queue_glob; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$newest_m" ]; then newest_m=$m; newest=$f; fi
  done
  if [ -n "$newest" ]; then
    if [ "$(queue_is_stale "$newest_m" "$(date +%s)" "$(tail -n 1 "$newest")")" = yes ]; then queue_state=stale; else queue_state=recent; fi
  fi
fi
printf 'queue\t%s\n' "$queue_state" >> "$tmp"

snapshot=$(cat "$tmp")
# Every open pull request keeps moving, not only the round's own: REST
# lists them, and each one's mergeable_state says whether it conflicts with
# main; a red one also gets how many times it was red. One call for the
# list, one per pull request, one more per red one; all REST.
rest_lines=""
pr_list=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [(.number | tostring), .head.ref, ([.labels[].name] | join(",")), ((.body // "") | [splits("\r?\n")] | map(select(test("^Queue: hold"; "i"))) | first // ""), ((.body // "") | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]] | join(","))] | @tsv' 2>/dev/null | tr -d '\r')
pull_links=""
while IFS="$tab" read -r p_num p_ref p_labels p_hold p_closes; do
  [ -n "$p_num" ] || continue
  pull_links="${pull_links}${p_num}${tab}$(held_by "$p_labels" "$p_hold")${tab}${p_closes}
"
  p_info=$(gh api "repos/{owner}/{repo}/pulls/$p_num" --jq '[(.mergeable_state // ""), .head.sha] | @tsv' 2>/dev/null | tr -d '\r')
  p_state=$(printf '%s' "$p_info" | cut -f1); p_sha=$(printf '%s' "$p_info" | cut -f2)
  p_reds=0; p_ci=$(printf '%s\n' "$snapshot" | awk -F'\t' -v n="$p_num" '$1 == "pr" && $2 == n { print $4 }')
  [ "$p_ci" = red ] && p_reds=$(red_count "$(gh api "repos/{owner}/{repo}/actions/runs?branch=$p_ref&event=pull_request&status=failure&per_page=100" --jq '.workflow_runs[].head_sha' 2>/dev/null)")
  # Someone else on it? Only for one the drive would send an agent to (it
  # conflicts with main, or it is red): a head commit or a newest comment
  # under 30 minutes old means an agent in another session is likely at
  # work, so this one gets none. Two more calls, for those only.
  p_busy=no
  if [ "$p_state" = dirty ] || [ "$p_ci" = red ]; then
    p_head=$(gh api "repos/{owner}/{repo}/commits/$p_sha" --jq '.commit.committer.date | fromdateiso8601' 2>/dev/null | tr -d '\r')
    p_since=$(date -u -d "@$(( $(date +%s) - 1800 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) - 1800 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    p_note=$(gh api "repos/{owner}/{repo}/issues/$p_num/comments?since=$p_since&per_page=100" --jq '[.[].created_at | fromdateiso8601] | max // empty' 2>/dev/null | tr -d '\r')
    p_busy=$(recently_touched "$p_head" "$p_note" "$(date +%s)" 30)
  fi
  rest_lines="${rest_lines}${p_num}${tab}${p_state}${tab}${p_reds}${tab}$(held_by "$p_labels" "$p_hold")${tab}${p_busy}
"
done <<EOF_PRS
$pr_list
EOF_PRS
[ -n "$rest_lines" ] && snapshot=$(overlay_rest "$snapshot" "$rest_lines")
[ "$show_snapshot" = yes ] && { echo "snapshot:"; printf '%s\n' "$snapshot"; echo; }
# What the saved digest adds: goals that labels alone miss, such as an
# issue still labeled waiting on owner that the owner has answered. Only
# summaries that are current count.
extra=""
if [ -f .scratch/board/digest.tsv ] && [ -f "$here/../board/board-lib.sh" ]; then
  . "$here/../board/board-lib.sh"
  saved=$(cat .scratch/board/digest.tsv)
  extra=$(digest_goals "$facts" "$saved")
  fresh=$(digest_freshness "$facts" "$saved")
  note="digest: ${fresh%%	*} of ${fresh##*	} summaries current"
else
  note="digest: none yet; run /project-status so the proposal reads bodies and comments, not only labels"
fi

# How many agents may work at once is what GitHub's registered runners say: online and not busy, less one kept for the queue.
listing=$(gh api 'repos/{owner}/{repo}/actions/runners?per_page=100' --jq '.runners[] | [.status, (.busy | tostring)] | @tsv' 2>/dev/null | tr -d '\r')
runners_line=$(agent_runners "$listing" "$runners_cap")
machines=no
if [ -n "$runners_line" ]; then machines=yes; runners=${runners_line%%	*}; runners_say=$(agent_runners_say "$runners_line" "$runners_cap")
else [ "$runners_cap" -gt 0 ] && runners=$runners_cap; runners_say="runners not readable from GitHub, so $runners"; fi
echo "proposal for $(date '+%A %Y-%m-%d'), the owner's local day (${runners_say}, at most $max_agents agents, at most $max_minutes minutes; $note):"
# In progress is not taken on faith: an issue nobody works, or whose pull request is held for the owner, is set right first (./stale-lib.sh).
stale=$(stale_lines "$facts" "$pull_links" "$(git for-each-ref --format='%(committerdate:unix)%09%(refname:short)' refs/heads refs/remotes 2>/dev/null)" "$(date +%s)" 2)
if [ -n "$stale" ]; then
  stale_say "$stale" 2
  stale_apply "$stale" "$facts"
  facts=$(stale_facts "$facts" "$stale"); snapshot=$(stale_snapshot "$snapshot" "$stale")
fi
units_per_round=$(setting "$settings" unitsPerRound)
aside_after=$(setting "$settings" setAsideAfterReds)
round=$(propose_round "$snapshot" "$runners" "$max_agents" "$aside_after")
# Plan the ready issues by the files they touch: overlapping guesses become
# one bundle (one agent, one pull request), disjoint ones stay apart, and an
# issue touching files a running issue touches is held, naming it.
mocks_text=""; [ -f scripts/ci/mocks.txt ] && mocks_text=$(cat scripts/ci/mocks.txt)
past=$(past_spec_files "$(git log -n 300 --name-only --format='@@ %s' main 2>/dev/null || git log -n 300 --name-only --format='@@ %s' 2>/dev/null)")
guesses=""; running=""
# A ready issue that says it comes after another open one is held, naming what it waits on, read afresh each run.
reasons=$(hold_reasons "$facts")
while IFS="$tab" read -r kind num title a b c d e; do
  [ "$kind" = issue ] || continue
  case "$(state_of_labels "$a")" in
    ready)
      case "$(printf '%s\n' "$snapshot" | awk -F'\t' -v n="$num" '$1 == "issue" && $2 == n { print $5 }')" in yes) continue ;; esac
      printf '%s\n' "$reasons" | grep -q "^hold	$num	" && continue
      g=$(guess_files "$title $c" "$mocks_text" "$past")
      guesses="${guesses}${num}${tab}${title}${tab}${g}
" ;;
    in-progress)
      g=$(guess_files "$title $c" "$mocks_text" "$past")
      [ -n "$g" ] && running="${running}${title}${tab}${g}
" ;;
  esac
done <<EOF_FACTS
$facts
EOF_FACTS
if [ -n "$guesses" ] || [ -n "$reasons" ]; then
  units=$(plan_units "$guesses" "$running")
  [ -n "$reasons" ] && units=$(printf '%s\n%s\n' "$units" "$reasons" | sed '/^$/d')
  # The proposal is the next round: up to unitsPerRound units (within
  # maxAgents), planned against the running round's files. It starts only
  # once the running round lands (approval.sh holds its dispatches).
  slots=$units_per_round; [ "$max_agents" -lt "$slots" ] && slots=$max_agents; [ "$runners" -lt "$slots" ] && slots=$runners
  round=$(apply_units "$round" "$units" "$slots" "$machines")
fi
# A project whose queue lands green work by itself: rely on it, and
# propose one drain only when green work has sat 15 minutes.
green_prs=$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "pr" && $4 == "green" && $5 == "mergeable" { print $2 }')
runs=""
if [ -f scripts/ci/merge-queue.sh ] && [ -n "$green_prs" ]; then
  runs=$(gh api "repos/{owner}/{repo}/actions/runs?per_page=50" --jq '.workflow_runs[] | [.status, (.run_started_at // .created_at | fromdateiso8601), (.updated_at | fromdateiso8601), .path, .event, .head_branch] | @tsv' 2>/dev/null | tr -d '\r')
  ages=""
  for p in $green_prs; do
    p_ref=$(printf '%s\n' "$facts" | awk -F'\t' -v n="$p" '$1 == "pr" && $2 == n { print $6; exit }')
    m=$(green_minutes "$runs" "$p_ref" "$(date +%s)")
    ages="${ages}${p}${tab}${m:-0}
"
  done
  round=$(landing_goals "$round" "$ages" 15)
fi
# Unreleased plugin work: one release goal, from this repository's history.
plugin_ver=$(json_field "$(cat plugin/.claude-plugin/plugin.json 2>/dev/null)" version)
rel_line=$(release_goal "$plugin_ver" "$(plugin_unreleased_count)")
[ -n "$rel_line" ] && round=$(add_goal "$round" "$rel_line")
if [ -n "$extra" ]; then
  round=$(printf '%s\n%s\n' "$extra" "$round" | awk '/^stop: (nothing to propose|everything left waits|work is in flight)/ { print "stop: proposal ready for approval"; next } { print }')
fi
number_proposal "$round"
# Auto Drive, from the drive issue's label drive:auto: one REST call. On is a
# standing approval; off, the proposal is posted and waits for a reply.
auto=$(auto_drive_state "$(gh api "$AUTO_DRIVE_QUERY" --jq "$AUTO_DRIVE_JQ" 2>/dev/null)")
auto_line "$auto"
model=$(setting "$settings" dispatchModel)
if [ "$aside_after" -gt 0 ] 2>/dev/null; then aside_words="a pull request red $aside_after times is set aside"; else aside_words="a red pull request is never set aside"; fi
echo "rounds: at most $units_per_round units a round, one round at a time; each unit's agent on ${model:-the model the agent-model hook allows}; $aside_words"
# The once-a-day summary, when summaryAt is set: due at that local time
# until a comment "Summary for <today>" is on the drive issue (one REST
# call, for the last day's comments only).
summary_at=$(setting "$settings" summaryAt)
drive_issue=${auto#* }
if [ -n "$summary_at" ] && [ "$auto" != none ] && [ "$(summary_due "$(date +%H:%M)" "$summary_at" no)" = yes ]; then
  today=$(date +%Y-%m-%d)
  since_e=$(( $(date +%s) - 86400 ))
  since=$(date -u -d "@$since_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$since_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  written=no
  gh api "repos/{owner}/{repo}/issues/$drive_issue/comments?since=$since&per_page=100" --jq '.[].body' 2>/dev/null | grep -q "^Summary for $today" && written=yes
  [ "$(summary_due "$(date +%H:%M)" "$summary_at" "$written")" = yes ] && echo "summary: due; post today's summary on issue $drive_issue, starting \"Summary for $today\""
fi
# The health note, when healthNote is set: a recommendation, never a pause.
health_cmd=$(setting "$settings" healthCommand)
if [ -n "$health_cmd" ]; then
  if command -v timeout >/dev/null 2>&1; then hv=$(timeout 30 sh -c "$health_cmd" 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d ' ')
  else hv=$(sh -c "$health_cmd" 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d ' '); fi
  health_line "$(setting "$settings" healthName)" "$hv" "$(setting "$settings" healthAbove)"
fi

# A pending pull request: say when to look again. One REST call for recent runs.
pend_pr=$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "pr" && $4 == "pending" { print $2; exit }')
if [ -n "$pend_pr" ]; then
  [ -n "$runs" ] || runs=$(gh api "repos/{owner}/{repo}/actions/runs?per_page=50" --jq '.workflow_runs[] | [.status, (.run_started_at // .created_at | fromdateiso8601), (.updated_at | fromdateiso8601), .path, .event, .head_branch] | @tsv' 2>/dev/null | tr -d '\r')
  branch=$(gh api "repos/{owner}/{repo}/pulls/$pend_pr" --jq .head.ref 2>/dev/null | tr -d '\r')
  # The pending run is the one for that pull request's branch, else the first not completed.
  pending=$(printf '%s\n' "$runs" | awk -F'\t' -v b="$branch" '$1 != "completed" && $1 != "" && b != "" && $6 == b { print; exit }')
  [ -n "$pending" ] || pending=$(printf '%s\n' "$runs" | awk -F'\t' '$1 != "completed" && $1 != "" { print; exit }')
  started=$(printf '%s\n' "$pending" | awk -F'\t' '{ print $2 }')
  durations=$(run_durations "$runs" "$(printf '%s\n' "$pending" | awk -F'\t' '{ print $4 }')" "$(printf '%s\n' "$pending" | awk -F'\t' '{ print $5 }')")
  secs=$(wake_after "$durations" "$started" "$(date +%s)")
  [ -n "$secs" ] && echo "wake: $secs seconds, PR $pend_pr"
fi
