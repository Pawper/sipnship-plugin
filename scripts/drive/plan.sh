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
. "$here/../../hooks/scripts/board-checks-lib.sh"
. "$here/../../hooks/scripts/session-brief-versions.sh"
. "$here/drive-lib.sh"
. "$here/auto-lib.sh"
. "$here/bundle-lib.sh"
. "$here/round-lib.sh"
. "$here/round-notes-lib.sh"
. "$here/round-words-lib.sh"
. "$here/round-sizing-lib.sh"
. "$here/round-state-lib.sh"
. "$here/areas-lib.sh"
. "$here/area-plan-lib.sh"
. "$here/plan-read-lib.sh"
. "$here/plan-green-lib.sh"
. "$here/comment-lib.sh"
. "$here/priority-lib.sh"
. "$here/ask-gate-lib.sh"
. "$here/stale-lib.sh"
. "$here/release-lib.sh"
. "$here/rank-lib.sh"
. "$here/pr-read-lib.sh"
. "$here/owner-lib.sh"

show_snapshot=no; fast=no; facts_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) show_snapshot=yes ;;
    --fast) fast=yes ;;
    --facts) shift; facts_file=$1 ;;
  esac
  shift
done

runners=2; runners_cap=0; max_agents=4; max_minutes=90; queue_glob=""; owner_phrases=""; priorities=""
settings=$(drive_settings '{}')
if [ -f .claude/project-drive.json ]; then
  cfg=$(cat .claude/project-drive.json)
  n=$(json_number "$cfg" runners); [ -n "$n" ] && runners_cap=$n
  n=$(json_number "$cfg" maxAgents); [ -n "$n" ] && max_agents=$n
  n=$(json_number "$cfg" maxMinutes); [ -n "$n" ] && max_minutes=$n
  queue_glob=$(json_field "$cfg" queueLogGlob)
  settings=$(drive_settings "$cfg"); priorities=$(drive_priorities "$cfg")
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
  elif [ "$(token_refusal "$(cat "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null)")" = yes ]; then
    echo "GitHub refused the board read for this token's permissions ($(tr -d '\r' < "${TMPDIR:-/tmp}/board-now.$$.err" | head -n 1 | cut -c1-160)); gh is signed in, but the token cannot read what the round needs. Give it Actions, Administration (read, to list runners), Commit statuses, Contents, Issues, Pull requests and Workflows."
    echo "stop: token permissions"
  else
    echo "gh is not available or not signed in; the round cannot read the project."
    echo "stop: unavailable"
  fi
  rm -f "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null
  exit 0
fi
grep -q "can't read check results" "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null && plan_say "this token can't read check results; the checks are read from the Actions runs and commit statuses instead"
rm -f "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null
plan_say "read the board: $(printf '%s\n' "$facts" | grep -c '^issue') issues, $(printf '%s\n' "$facts" | grep -c '^pr') pull requests"

rules=""
[ -f scripts/ci/classes.txt ] && [ -f scripts/ci/lib.sh ] && rules=$(cat scripts/ci/classes.txt)
tab=$(printf '\t'); us=$(printf '\037')
tmp=$(mktemp)

# Turn the facts into a snapshot, with no further network calls.
printf '%s\n' "$facts" | tr '\t' '\037' | while IFS="$us" read -r kind num title a b c d e; do
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
          # Title and the start of the body, both from the one call; an owner-decision match is a candidate with its sentence.
          printf 'issue\t%s\t%s\tready\t%s\n' "$num" "$title" "$(owner_issue_fields "$num" "$title" "$c" "$owner_phrases")" ;;
        in-progress|waiting-on-owner|blocked)
          printf 'issue\t%s\t%s\t%s\tno\n' "$num" "$title" "$state" ;;
      esac
      ;;
  esac
done >> "$tmp"

# The audit issue's latest comment: one extra call, skipped with --fast.
if [ "$fast" = no ]; then audit_last_line "$facts" >> "$tmp"; fi

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
batch_pr=$(open_batch_pr); [ -n "$batch_pr" ] && queue_state="batch $batch_pr"
printf 'queue\t%s\n' "$queue_state" >> "$tmp"

snapshot=$(cat "$tmp")
# Every open pull request keeps moving (pr-read-lib.sh): its state, red count and busy flag are overlaid on the snapshot.
read_open_pull_requests
[ "$show_snapshot" = yes ] && { echo "snapshot:"; printf '%s\n' "$snapshot"; echo; }
# What the saved digest adds: goals that labels alone miss, such as an
# issue still labeled waiting on owner that the owner has answered. Only
# summaries that are current count.
extra=""
if [ -f .scratch/board/digest.tsv ] && [ -f "$here/../board/board-lib.sh" ]; then
  . "$here/../board/board-lib.sh"
  saved=$(cat .scratch/board/digest.tsv)
  extra=$(digest_goals "$facts" "$saved")
  # An open question is proposed as mark-waiting only when its ask is in the shape (scripts/ci/ask-lib.sh); otherwise as ask-fix.
  if [ -f scripts/ci/ask-lib.sh ]; then . scripts/ci/ask-lib.sh; . "$here/ask-gate-lib.sh"; extra=$(mark_waiting_goals "$extra" "$(ask_verdicts_for "$extra")"); fi
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
# The round file's own line for it (publish-round.sh's "sized:"), so the Work band says how many agents and why.
echo "sized: ${runners_say}"
# In progress is not taken on faith: an issue nobody works, or whose pull request is held for the owner, is set right first (./stale-lib.sh).
drive_line=$(drive_issue_line)
drive_comments=$(read_drive_comments "$drive_line")
stale=$(stale_lines "$facts" "$pull_links" "$(git for-each-ref --format='%(committerdate:unix)%09%(refname:short)' refs/heads refs/remotes 2>/dev/null)" "$(date +%s)" 2 "$(started_units "$drive_comments")")
if [ -n "$stale" ]; then
  stale_say "$stale" 2
  stale_apply "$stale" "$facts"
  facts=$(stale_facts "$facts" "$stale"); snapshot=$(stale_snapshot "$snapshot" "$stale")
fi
units_per_round=$(setting "$settings" unitsPerRound)
aside_after=$(setting "$settings" setAsideAfterReds)
MAINFIX_ISSUES=$(mainfix_numbers "$facts"); export MAINFIX_ISSUES  # ready fixes for a failure on main lead (rank-lib.sh)
round=$(propose_round "$snapshot" "$runners" "$max_agents" "$aside_after")
# Plan the ready issues by the files they touch: overlapping guesses become
# one bundle (one agent, one pull request), disjoint ones stay apart, and an
# issue touching files a running issue touches is held, naming it.
mocks_text=""; [ -f scripts/ci/mocks.txt ] && mocks_text=$(cat scripts/ci/mocks.txt)
areas_text=""; [ -f .claude/areas.txt ] && areas_text=$(cat .claude/areas.txt)
past=$(past_spec_files "$(git log -n 300 --name-only --format='@@ %s' main 2>/dev/null || git log -n 300 --name-only --format='@@ %s' 2>/dev/null)")
guesses=""; running=""
# A ready issue that says it comes after another open one is held, naming what it waits on, read afresh each run.
reasons=$(hold_reasons "$facts")
# An open pull request that already closes a Ready issue means no agent is started on it again, held or batched (stale-lib.sh).
reasons=$(printf '%s\n%s\n' "$reasons" "$(carried_holds "$facts" "$pull_links")" | sed '/^$/d')
# A started unit counts as running while its pull request is open, whatever State its issues show: none of its Ready issues is proposed for dispatch (one hold line each).
reasons=$(printf '%s\n%s\n' "$reasons" "$(started_ready_holds "$drive_comments" "$(printf '%s\n' "$pr_list" | cut -d"$us" -f1)" "$facts" "$snapshot")" | sed '/^$/d')
while IFS="$us" read -r kind num title a b c d e; do
  [ "$kind" = issue ] || continue
  case "$(state_of_labels "$a")" in
    ready)
      case "$(printf '%s\n' "$snapshot" | awk -F'\t' -v n="$num" '$1 == "issue" && $2 == n { print $5 }')" in yes) continue ;; esac
      printf '%s\n' "$reasons" | grep -q "^hold	$num	" && continue
      g=$(guess_files "$title $c" "$mocks_text" "$past"); [ -n "$g" ] || g=$(title_area_files "$title $c" "$areas_text")
      guesses="${guesses}${num}${tab}${title}${tab}${g}
" ;;
    in-progress)
      g=$(guess_files "$title $c" "$mocks_text" "$past")
      [ -n "$g" ] && running="${running}${title}${tab}${g}
" ;;
  esac
done <<EOF_FACTS
$(printf '%s\n' "$facts" | tr '\t' '\037')
EOF_FACTS
if [ -n "$guesses" ] || [ -n "$reasons" ]; then
  units=$(plan_units "$guesses" "$running")
  # The running round's areas, read as publish-round.sh reads them: an issue in an area a running unit owns is a hold behind it, and units sharing an area are one unit, so the proposal publishes as it stands.
  if [ -n "$areas_text" ]; then
    run_units=$(running_units "$(printf '%s\n' "$drive_comments" | cut -f3-)" "$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "issue" && $4 == "in-progress" { print $2 }')" "$(printf '%s\n' "$pr_list" | cut -d"$us" -f1)")
    issue_titles=$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "issue" { print $2 "\t" $3 }')
    units=$(area_units "$areas_text" "$units" "$run_units" "$issue_titles"); units=$(unplaced_holds "$units" "$guesses" "$run_units" "$issue_titles")
  fi
  # Issues a builder rushed (RUSH_ISSUES, space separated, read from work-requests.sh): their bundle leads.
  units=$(rush_first "$units" "${RUSH_ISSUES:-}")
  [ -n "$reasons" ] && units=$(printf '%s\n%s\n' "$units" "$reasons" | sed '/^$/d')
  # The proposal is the next round: up to unitsPerRound units (within
  # maxAgents), planned against the running round's files. It starts only
  # once the running round lands (approval.sh holds its dispatches).
  slots=$units_per_round; [ "$max_agents" -lt "$slots" ] && slots=$max_agents; [ "$runners" -lt "$slots" ] && slots=$runners
  round=$(apply_units "$round" "$units" "$slots" "$machines" "$MAINFIX_ISSUES" "$(priority_issues "$priorities" "$guesses" "$facts" "$areas_text")")  # a project's priority areas lead, after a fix for main
  round=$(lead_main_fixes "$round")  # the fix for a failure on main opens the proposal and the approval never holds it behind the round it blocks (rank-lib.sh)
fi
# A project whose queue lands green work by itself: rely on it; propose one drain only when green work has sat 15 minutes.
green_prs=$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "pr" && $4 == "green" && $5 == "mergeable" && $8 != "yes" { print $2 }')
runs=""
if [ -f scripts/ci/merge-queue.sh ] && [ -n "$green_prs" ]; then
  runs=$(gh api "repos/{owner}/{repo}/actions/workflows/queue-drain.yml/runs?per_page=20" --jq '.workflow_runs[] | [.status, (.run_started_at // .created_at | fromdateiso8601), (.updated_at | fromdateiso8601), .path, .event, .head_branch] | @tsv' 2>/dev/null | tr -d '\r')
  ages=$(green_ages "$(printf '%s' "$green_prs" | tr '\n' ' ')" "$pr_shas" "$(date +%s)")  # each head commit's own check runs (plan-green-lib.sh), never a window of recent runs
  round=$(plan_landing "$round" "$ages" "$batch_pr" "$snapshot" "$runs")  # batch members and held pull requests never count toward a drain
  round=$(hold_drain_for_main "$round" "$MAINFIX_ISSUES")  # no drain while main fails the test a batch would fail on (rank-lib.sh)
fi
# Unreleased plugin work, read from the remote's main (release-lib.sh): one release goal, or a hold naming the pull request or issue already making it.
round=$(add_release "$round" "$(release_proposal "$facts" "$pull_links")")
[ -z "$extra" ] || round=$(add_owner_goals "$round" "$extra" "$facts" .scratch/drive/ask-fix.txt)  # an ask-fix the drive already tried stays a hold (ask-fix-seen.sh)
round=$(say_every_pr "$round" "$snapshot")  # every open pull request has a line, whatever its checks say
number_proposal "$round"
# Auto Drive, from the drive issue's label drive:auto: one REST call. On is a
# standing approval; off, the proposal is posted and waits for a reply.
auto=$(auto_drive_state "$drive_line")
auto_line "$auto"
model=$(setting "$settings" dispatchModel)
if [ "$aside_after" -gt 0 ] 2>/dev/null; then aside_words="a pull request red $aside_after times is set aside"; else aside_words="a red pull request is never set aside"; fi
echo "rounds: at most $units_per_round units a round, one round at a time; each unit's agent on ${model:-the model the agent-model hook allows}; $aside_words"
held_wait_note "${held_since:-}" "$(date +%s)"
summary_note
health_note
wake_note
[ "$fast" = yes ] || plugin_note
