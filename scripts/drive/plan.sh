#!/bin/sh
# Gather the project's state and print the proposal the project-drive skill
# would put to a person. This script never acts: it reads, decides, prints.
# The skill posts the proposal and, once approved, pursues it.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/plan.sh" [--dry-run] [--snapshot] [--fast] [--facts FILE]
# --dry-run changes nothing (always dry); --snapshot also prints the raw facts;
# --facts FILE reuses facts from board-now.sh; --fast skips the audit-comment call.
# The whole board comes from one GraphQL call (hooks/scripts/board-now.sh).
# Reads .claude/project-drive.json when present: runners (an optional cap on
# the agents at once; with none, the runners GitHub lists online and free decide),
# maxAgents (4), maxMinutes (90), queueLogGlob, ownerDecisions, and the
# round's choices drive_settings reads (round-lib.sh): unitsPerRound (2),
# dispatchModel, setAsideAfterReds (2), summaryAt, healthNote.
# Open pull requests are read again over REST (round-lib.sh, overlay_rest): one
# conflicting with main is merge-main, one red too often is set-aside.
here=$(dirname "$0")

# The whole run is bounded (#1937): one that has not finished in PLAN_SECONDS (600) is stopped and says so in one plain
# line, so a tick is never lost to a loop. The run starts again once, under the bound, with the same words.
if [ -z "${PLAN_BOUNDED:-}" ] && command -v timeout >/dev/null 2>&1; then
  PLAN_BOUNDED=1 timeout "${PLAN_SECONDS:-600}" sh "$0" "$@"; plan_rc=$?
  if [ "$plan_rc" -eq 124 ]; then
    echo "plan did not finish in ${PLAN_SECONDS:-600} seconds and was stopped; the round has nothing to propose until it does."
    echo "stop: plan did not finish"
    exit 0
  fi
  exit "$plan_rc"
fi

. "$here/../../hooks/scripts/lib.sh"
. "$here/../../hooks/scripts/session-brief-lib.sh"
. "$here/../../hooks/scripts/board-checks-lib.sh"
. "$here/../../hooks/scripts/session-brief-versions.sh"
[ -f "$here/../../templates/scripts/ci/git-bounded-lib.sh" ] && . "$here/../../templates/scripts/ci/git-bounded-lib.sh"
. "$here/drive-lib.sh"
. "$here/labels-lib.sh"
. "$here/auto-lib.sh"
. "$here/bundle-lib.sh"; . "$here/hold-reasons-lib.sh"
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
. "$here/held-round-lib.sh"
. "$here/ask-gate-lib.sh"
. "$here/../../templates/scripts/ci/ask-lib.sh"  # held_ask for the stale issues' asks, from the plugin's own copy
. "$here/plan-holds-lib.sh"
. "$here/stale-lib.sh"; . "$here/held-running-lib.sh"
. "$here/release-lib.sh"
. "$here/deploy-goal-lib.sh"
. "$here/rank-lib.sh"
. "$here/red-batch-lib.sh"
. "$here/pr-read-lib.sh"; . "$here/owner-lib.sh"; . "$here/left-lib.sh"; . "$here/asked-lib.sh"; . "$here/set-aside-lib.sh"; . "$here/round-bound-lib.sh"; . "$here/left-reader-lib.sh"

# No GitHub call waits for ever (#1794): a call that has not answered in PLAN_GH_SECONDS (120) is stopped, the plan
# names it on its error stream, and reads what that call would have told as not known, as for any failed call.
plan_gh_bin=$(command -v gh 2>/dev/null)
if [ -n "$plan_gh_bin" ] && command -v timeout >/dev/null 2>&1; then
  gh() {
    timeout "${PLAN_GH_SECONDS:-120}" "$plan_gh_bin" "$@"; gh_rc=$?
    [ "$gh_rc" -ne 124 ] || echo "plan: a GitHub call (gh $(printf '%s' "$*" | cut -c1-80)) did not answer in ${PLAN_GH_SECONDS:-120} seconds and was stopped" >&2
    return "$gh_rc"
  }
fi

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

# Turn the facts into a snapshot (plan-read-lib.sh).
snapshot_rows "$facts" "$rules" "$owner_phrases" >> "$tmp"

# The audit issue's latest comment: one extra call, skipped with --fast.
if [ "$fast" = no ]; then audit_last_line "$facts" >> "$tmp"; fi

queue_state=$(queue_state_of "$queue_glob")
batch_pr=$(open_batch_pr); [ -n "$batch_pr" ] && queue_state="batch $batch_pr"
printf 'queue\t%s\n' "$queue_state" >> "$tmp"

plan_stage "board read"
snapshot=$(cat "$tmp")
# Every open pull request keeps moving (pr-read-lib.sh): its state, red count and busy flag are overlaid on the snapshot.
read_open_pull_requests
[ "$show_snapshot" = yes ] && { echo "snapshot:"; printf '%s\n' "$snapshot"; echo; }
# What the saved digest adds: goals that labels alone miss, such as an
# issue still labeled waiting on owner that the owner has answered. Only
# summaries that are current count.
extra=""
# The drive issue's comments, read once: the started round's units and the time it started.
plan_stage "pull requests read"
drive_line=$(drive_issue_line)
drive_comments=$(read_drive_comments "$drive_line")
if [ -f .scratch/board/digest.tsv ] && [ -f "$here/../board/board-lib.sh" ]; then
  . "$here/../board/board-lib.sh"
  saved=$(cat .scratch/board/digest.tsv)
  extra=$(digest_goals "$facts" "$saved")
  # An open question counts only while no answer follows it, and an issue a started unit owns is its agent's, not the owner's.
  extra=$(drop_waiting_goals "$extra" "$(answered_for "$extra")")
  # A closing note of what an agent left is not a question to the owner, so it is neither marked waiting nor sent back to be reshaped (#1712).
  extra=$(drop_waiting_goals "$extra" "$(closing_notes_for "$extra")")
  extra=$(drop_waiting_goals "$extra" "$(unit_issues "$(started_units "$drive_comments")")")
  # What waits on an issue a held pull request closes is the builder's read of that pull request, which has its own hold line; no question is open on the issue (#1798).
  extra=$(drop_waiting_goals "$extra" "$(held_closing_issues "$pull_links")")
  # An open question is proposed as mark-waiting only when its ask is in the shape (scripts/ci/ask-lib.sh); otherwise as ask-fix.
  if [ -f scripts/ci/ask-lib.sh ]; then . scripts/ci/ask-lib.sh; . "$here/ask-gate-lib.sh"; extra=$(mark_waiting_goals "$extra" "$(ask_verdicts_for "$extra")"); fi
  fresh=$(digest_freshness "$facts" "$saved")
  note="digest: ${fresh%%	*} of ${fresh##*	} summaries current"
else
  note="digest: none yet; run /project-status so the proposal reads bodies and comments, not only labels"
fi
# An issue waiting on the builder with no question on it is the drive's to set right, never the builder's (ask-gate-lib.sh).
extra=$(printf '%s\n%s\n' "$extra" "$(unasked_goals "$facts" "$here/../../templates/scripts/ci/ask-audit.sh")" | sed '/^$/d')
extra=$(drop_standing_goals "$extra" "$facts")  # the drive and audit issues are never proposed as work or as a question (#1845)

# Runners are looked at once, for the round as a whole (how many are online, for the sized line); they never set how many agents start.
plan_stage "answers and asks read"
runners_online=$(gh api 'repos/{owner}/{repo}/actions/runners?per_page=100' --jq '[.runners[] | select(.status == "online")] | length' 2>/dev/null | tr -d '\r')
[ "$fast" = yes ] || plugin_note  # first line of the output: a proposal made by an old plan is read as such (#1846)
echo "proposal for $(date '+%A %Y-%m-%d'), the owner's local day (at most $max_agents agents, at most $max_minutes minutes; $note):"
# In progress is not taken on faith: an issue nobody works, or whose pull request is held for the owner, is set right first (./stale-lib.sh).
stale=$(stale_lines "$facts" "$pull_links" "$(gitb for-each-ref --format='%(committerdate:unix)%09%(refname:short)' refs/heads refs/remotes 2>/dev/null)" "$(date +%s)" 2 "$(started_units "$drive_comments")" "$(started_at "$drive_comments")")
if [ -n "$stale" ]; then
  stale_say "$stale" 2
  stale_apply "$stale" "$facts"
  facts=$(stale_facts "$facts" "$stale"); snapshot=$(stale_snapshot "$snapshot" "$stale")
fi
# A held pull request whose question has been answered is said, so nobody reads the answer as the hold's release.
held_answered=$(held_answered_lines "$pull_links")
[ -z "$held_answered" ] || printf '%s\n' "$held_answered"
plan_stage "stale issues checked"
units_per_round=$(setting "$settings" unitsPerRound)
aside_after=$(setting "$settings" setAsideAfterReds)
MAINFIX_ISSUES=$(mainfix_numbers "$facts"); export MAINFIX_ISSUES  # ready fixes for a failure on main lead (rank-lib.sh)
round=$(propose_round "$snapshot" "$max_agents" "$max_agents" "$aside_after")
# A set-aside already done (its issue blocked, the cause written after the pull request's last red run) is a note, not a goal again (set-aside-lib.sh).
round=$(drop_settled_set_asides "$round" "$pr_list" "$snapshot")
# Plan the ready issues by the files they touch: overlapping guesses become
# one bundle (one agent, one pull request), disjoint ones stay apart, and an
# issue touching files a running issue touches is held, naming it.
plan_stage "round proposed"
mocks_text=""; [ -f scripts/ci/mocks.txt ] && mocks_text=$(cat scripts/ci/mocks.txt)
areas_text=""; [ -f .claude/areas.txt ] && areas_text=$(cat .claude/areas.txt)
past=$(past_spec_files "$(gitb log -n 300 --name-only --format='@@ %s' main 2>/dev/null || gitb log -n 300 --name-only --format='@@ %s' 2>/dev/null)")
asked=$(asked_issues "$drive_comments"); ASKED_ISSUES=$asked; export ASKED_ISSUES; asked_notes=""  # issues the builder asked for by name keep their place until done (asked-lib.sh, #1930)
held_only=$(held_only_issues "$pull_links" | tr "
" " "); guesses=""; running=""; left_reads=0; left_lines=""; plan_left_until=$((SECONDS + ${PLAN_LEFT_SECONDS:-90}))
# A ready issue that says it comes after another open one is held, naming what it waits on, read afresh each run.
reasons=$(hold_reasons "$facts" "$held_only")
# An open pull request that already closes a Ready issue means no agent is started on it again, held or batched (stale-lib.sh).
reasons=$(printf '%s\n%s\n' "$reasons" "$(carried_holds "$facts" "$pull_links")" | sed '/^$/d')
# A started unit counts as running while its pull request is open, whatever State its issues show: none of its Ready issues is proposed for dispatch (one hold line each).
reasons=$(printf '%s\n%s\n' "$reasons" "$(started_ready_holds "$drive_comments" "$(printf '%s\n' "$pr_list" | cut -d"$us" -f1)" "$facts" "$snapshot")" | sed '/^$/d')
# The holds the drive published in its last round, with their reasons still true, take no slot again (held-round-lib.sh): the slots go to the next ready unit.
published=$(published_holds "$drive_comments" "$facts" "$(printf '%s\n' "$pr_list" | cut -d"$us" -f1)")
published=$(printf '%s\n' "$published" | awk -F'\t' -v r="$reasons" 'BEGIN { n = split(r, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, "\t"); if (f[1] == "hold") seen[f[2]] = 1 } } NF && !($2 in seen)')  # an issue a hold line already names is not held twice
reasons=$(printf '%s\n%s\n' "$reasons" "$published" | sed '/^$/d')
published_count=$(printf '%s\n' "$published" | sed '/^$/d' | cut -f2 | sort -u | wc -l | tr -d ' ')
while IFS="$us" read -r kind num title a b c d e; do
  [ "$kind" = issue ] || continue
  labels_facts "$a"  # no process started per issue (labels-lib.sh, #1794)
  [ "$lf_standing" = yes ] && continue  # the drive and audit issues take no dispatch and no slot
  [ "$lf_red" = yes ] && continue  # a red main's issue is the fix-main goal alone, never a dispatch or a bundle member (#1879)
  case "$lf_state" in
    ready)
      case "$(printf '%s\n' "$snapshot" | awk -F'\t' -v n="$num" '$1 == "issue" && $2 == n { print $5 }')" in yes) continue ;; esac
      case "
$reasons" in *"
hold	$num	"*) continue ;; esac
      plan_ready_guess  # sets g and title; an issue a merged pull request worked on is planned from what is left (left-lib.sh)
      case "$left_say" in partly) lr_state=$(left_read_state "$num" .scratch/drive/left-read.tsv); left_lines="${left_lines}${num}${tab}${title}${tab}${lr_state}
"; reasons=$(printf '%s\nhold\t%s\t%s\t%s\n' "$reasons" "$num" "$title" "$(left_read_hold_why "$lr_state")" | sed '/^$/d'); continue ;; esac  # a partly landed issue is a hold until its reader has written what is left (#1891, #2047)
      case " $asked " in *" $num "*) asked_notes="${asked_notes}asked: ${num} $(asked_line "$left_say")
" ;; esac
      guesses="${guesses}${num}${tab}${title}${tab}${g}
" ;;
    in-progress)
      g=$(guess_files "$title $c" "$mocks_text" "$past") ; case " $held_only " in *" $num "*) g="" ;; esac  # its only pull request is held for the owner: no agent is at work, so no unit waits behind it (#2055)
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
    run_units=$(running_units "$(printf '%s\n' "$drive_comments" | cut -f3-)" "$(without_issues "$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "issue" && $4 == "in-progress" { print $2 }')" "$held_only")" "$(without_issues "$(printf '%s\n' "$pr_list" | cut -d"$us" -f1)" "$(held_pull_numbers "$pull_links")")")  # a unit whose pull request is held for the owner is not running (#2055)
    issue_titles=$(issue_titles_from_facts "$facts"); units=$(area_units "$areas_text" "$units" "$run_units" "$issue_titles"); units=$(held_area_holds "$areas_text" "$units" "$(published_held_areas "$(printf '%s\n' "$drive_comments" | cut -f3-)")" "$published" "$issue_titles"); units=$(unplaced_holds "$units" "$guesses" "$run_units" "$issue_titles")
  fi
  # Issues a builder rushed (RUSH_ISSUES, space separated, read from work-requests.sh): their bundle leads.
  units=$(rush_first "$units" "${RUSH_ISSUES:-} $(printf '%s' "$asked_notes" | awk '$1 == "asked:" { printf "%s ", $2 }')")  # asked issues lead, as a rush does
  [ -n "$reasons" ] && units=$(printf '%s\n%s\n' "$units" "$reasons" | sed '/^$/d')
  # The proposal is the next round: up to unitsPerRound units (within
  # maxAgents), planned against the running round's files. It starts only
  # once the running round lands (approval.sh holds its dispatches).
  health_read; busy=$(computer_busy "$hv" "$(setting "$settings" healthAbove)"); slots=$(round_slots "$units_per_round" "$max_agents" "$busy")  # the limit and the computer's load, never free runners (#2084)
  round=$(apply_units "$round" "$units" "$slots" "${busy:-no}" "$MAINFIX_ISSUES" "$(priority_issues "$priorities" "$guesses" "$facts" "$areas_text")")  # a project's priority areas lead, after a fix for main
  round=$(defer_note "$round" "$published_count")  # a small round says which holds kept their issues out of it
  round=$(lead_main_fixes "$round")  # the fix for a failure on main opens the proposal and the approval never holds it behind the round it blocks (rank-lib.sh)
fi
round=$(add_left_readers "$round" "$left_lines")  # one reader goal for each partly landed issue not yet read (left-reader-lib.sh)
round=$(drop_asks_for_after_holds "$round")  # an issue that names what it follows is a hold, never also an ask (#1875)
# A project whose queue lands green work by itself: rely on it; propose one drain only when green work has sat 15 minutes.
plan_stage "ready issues placed"
green_prs=$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "pr" && $4 == "green" && $5 == "mergeable" && $8 != "yes" { print $2 }')
runs=""
if [ -f scripts/ci/merge-queue.sh ] && [ -n "$green_prs" ]; then
  runs=$(gh api "repos/{owner}/{repo}/actions/workflows/queue-drain.yml/runs?per_page=20" --jq '.workflow_runs[] | [.status, (.run_started_at // .created_at | fromdateiso8601), (.updated_at | fromdateiso8601), .path, .event, .head_branch] | @tsv' 2>/dev/null | tr -d '\r')
  ages=$(green_ages "$(printf '%s' "$green_prs" | tr '\n' ' ')" "$pr_shas" "$(date +%s)")  # each head commit's own check runs (plan-green-lib.sh), never a window of recent runs
  round=$(plan_landing "$round" "$ages" "$batch_pr" "$snapshot" "$runs")  # batch members and held pull requests never count toward a drain
  round=$(red_batch_goals "$round" "$(cat .scratch/queue/red-batches.tsv 2>/dev/null)" "$pr_shas" "$(git rev-parse -q --verify origin/main 2>/dev/null)")  # no drain for pull requests whose last batch went red on the same commits and the same main; the failing test is named (red-batch-lib.sh)
  round=$(hold_drain_for_main "$round" "$MAINFIX_ISSUES")  # no drain while main fails the test a batch would fail on (rank-lib.sh)
fi
round=$(held_green_line "$round" "$snapshot")  # green pull requests held for the builder's read: one line of their own, never landing and never toward a drain
# Unreleased plugin work, read from the remote's main (release-lib.sh): one release goal, or a hold naming the pull request or issue already making it.
round=$(add_release "$round" "$(release_proposal "$facts" "$pull_links")")
# Landed changes that are not live (deploy-goal-lib.sh): one deploy goal when production is behind main for ten minutes and none is running.
round=$(add_deploy "$round" "$(deploy_proposal)")
# A goal declined after a reader looked at the issue is not proposed again until the issue changes (goal-seen.sh).
round=$(quiet_declined_goals "$round" "$facts" .scratch/drive/declined.tsv); extra=$(quiet_declined_goals "$extra" "$facts" .scratch/drive/declined.tsv)
[ -z "$extra" ] || round=$(add_owner_goals "$round" "$extra" "$facts" .scratch/drive/ask-fix.txt)  # an ask-fix the drive already tried stays a hold (ask-fix-seen.sh)
round=$(say_every_pr "$round" "$snapshot")  # every open pull request has a line, whatever its checks say
plan_stage "landing, release and deploy read"
round=$(lead_red_main "$round")  # a red main's goal is the first numbered line (rank-lib.sh)
number_proposal "$round"; stall_note "$round"  # every ready issue held: said as a stall naming what frees the most (#2055)
# Auto Drive, from the drive issue's label drive:auto: one REST call. On is a
# standing approval; off, the proposal is posted and waits for a reply.
auto=$(auto_drive_state "$drive_line")
auto_line "$auto"
model=$(setting "$settings" dispatchModel)
if [ "$aside_after" -gt 0 ] 2>/dev/null; then aside_words="a pull request red $aside_after times is set aside"; else aside_words="a red pull request is never set aside"; fi
round_model=$(setting "$settings" roundModel)
[ -z "$asked_notes" ] || printf '%s' "$asked_notes"  # one line each: the kept request, in plain words (asked-lib.sh)
echo "sized: $(sized_words "$(printf '%s\n' "$units" | grep -c '^unit')" "$(printf '%s\n' "$round" | grep -c '^dispatch ')" "${slots:-$max_agents}" "${busy:-no}" "$runners_online" "${unread_prs:-0}")"  # what bounded the round, for the Work band
echo "rounds: at most $units_per_round units a round, one round at a time; each unit's agent on ${model:-the model the agent-model hook allows}; the round itself on ${round_model:-the app's default model}; $aside_words"
held_wait_note "${held_since:-}" "$(date +%s)"
summary_note
health_note
wake_note
