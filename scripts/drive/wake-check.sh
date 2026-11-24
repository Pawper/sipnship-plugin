#!/bin/sh
# Decide whether a woken run should start a drive tick. First the plan runs
# (plan.sh --fast), which publishes its proposed round to the Work tab by
# itself, so every look, timed or woken, leaves the tab a fresh round or says
# it could not (#2101); its output is kept in .scratch/drive/plan.txt for the
# tick. Then the approval (approval.sh) and the Work tab requests still owed
# (work-requests.sh) are read, all with no model, and it prints the plan's
# "published:" or "not published:" line, then "start: ..." or "nothing: why".
# Reading the approval after the publish is what lets the run that proposes
# also start, with Auto Drive on and no round running.
# With GITHUB_OUTPUT set (a workflow step), also writes start=yes or start=no
# and the reason, so the model step runs only when something is approved.
# WAKE_PLAN, WAKE_APPROVAL and WAKE_REQUESTS name other scripts for the plan, the approval and the owed requests (the suite's stand-ins, so a test never reads the real drive issue).
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/wake-check.sh"
here=$(dirname "$0")
. "$here/wake-lib.sh"
. "$here/round-lib.sh"
mkdir -p .scratch/drive 2>/dev/null
# First thing, by script: a copy behind the published version is brought up, whoever started this run.
sh "${WAKE_UPDATE:-$here/../release/update-if-behind.sh}" 2>/dev/null | tail -n 1
# And a release is prepared by script when plugin changes sit on main with no release open; nothing is printed when there is none.
sh "${WAKE_PREPARE:-$here/../release/prepare.sh}" 2>/dev/null | tail -n 1 | grep -v '^release: nothing to release' || true
# A red change with nobody on it is looked for first, by script, before the slow plan: its fix agent is owed within minutes (#1897).
sh "${WAKE_FIX_SIDE:-$here/fix-side.sh}" --apply 2>/dev/null | tail -n 3  # fixes a fix agent could not push are merged when what they wait on lands, with no model (#2260)
# An issue In progress whose claim's starter run has already ended, with no open pull request on it, is freed
# here too, by script, so a tick never reports "nothing to do" for one simply stuck behind its four-hour claim
# (#2328): this was a prior wake's agent, killed with its job, that pushed nothing. Only the lines that say
# something happened are carried into the report; "nothing to free" is not a line worth repeating every tick.
sh "${WAKE_CLAIM_STALE:-$here/claim-stale.sh}" --apply 2>/dev/null | grep '^claim-stale: freed\|^claim-stale: released the claim' || true
fix=$(sh "${WAKE_FIX_OWED:-$here/fix-owed.sh}" 2>/dev/null)
# The ten-minute look (WAKE_QUICK=yes) is only this: with no fix agent owed it ends here, with no plan and no model.
if [ "${WAKE_QUICK:-}" = yes ] && [ -z "$fix" ]; then
  echo "nothing: no red change is waiting for an agent"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "start=no" >> "$GITHUB_OUTPUT"; echo "why=no red change is waiting for an agent" >> "$GITHUB_OUTPUT"; fi
  exit 0
fi
sh "${WAKE_PLAN:-$here/plan.sh}" --fast > .scratch/drive/plan.txt 2>/dev/null
pub=$(grep -E '^(published|not published):' .scratch/drive/plan.txt | tail -n 1)
echo "${pub:-not published: the plan printed no proposal, so the Work tab still shows the last round it was given.}"
# The drive issue and its tracking comment (wake_repeat_read, #2342) are read once, here, before the
# approval runs rather than after: a round already proposed, with nothing started, for two looks running
# (one short of the stall line, "proposed 3 times... ") is not made to wait a whole twenty minutes for
# dead_round_issues to free a unit with no real evidence behind it (#2513). DEAD_ROUND_MINUTES, read by
# approval.sh's dead_round_issues call, is set to 0 for this one look, so the round is checked for
# evidence now and a unit with none is dropped at once, letting the rest of the round (or the next one)
# go rather than repeat the same "held:" line a third time with nobody freed.
rk=$(wake_round_key "$(cat .scratch/drive/round.txt 2>/dev/null)")
drive_issue=$(gh api "repos/{owner}/{repo}/issues?labels=drive&state=open&per_page=1" --jq '.[0] // empty | [(.number|tostring), (.comments|tostring)] | @tsv' 2>/dev/null | tr -d '\r')
wc_issue=$(printf '%s' "$drive_issue" | cut -f1)
wc_rows=""
if [ -n "$wc_issue" ]; then
  wc_count=$(printf '%s' "$drive_issue" | cut -f2)
  for wc_page in $(comment_pages "${wc_count:-0}"); do
    wc_rows="${wc_rows}$(gh api "repos/{owner}/{repo}/issues/$wc_issue/comments?per_page=100&page=$wc_page" --jq '.[] | "\(.id)\t" + (.body | gsub("[\r\n]+"; " "))' 2>/dev/null)
"
  done
fi
prev=$(wake_repeat_read "$wc_rows")
pk=$(printf '%s' "$prev" | cut -f1); pc=$(printf '%s' "$prev" | cut -f2)
case "$pc" in ''|*[!0-9]*) pc=0 ;; esac
if [ -n "$rk" ] && [ "$rk" = "$pk" ] && [ "$pc" -ge 2 ]; then
  export DEAD_ROUND_MINUTES=0
  echo "the round named $(printf '%s' "$rk" | sed 's/ /, #/g; s/^/#/') was proposed with nothing started $((pc + 1)) times running; its evidence is checked now, not after twenty minutes"
fi
out=$(sh "${WAKE_APPROVAL:-$here/approval.sh}" 2>&1)
# Goals approved from an older posted proposal that the plan no longer prints start nothing, and the tick says so (#2104).
stale=$(approved_not_planned "$(cat .scratch/drive/plan.txt 2>/dev/null)" "$out")
if [ -n "$stale" ]; then
  out=$(drop_stale_goals "$out" "$stale")
  out="nothing: the approval names goals the plan no longer prints (#$(printf '%s' "$stale" | tr '\n' ' ' | sed 's/ $//; s/ /, #/g')); none of them is started
$out"
fi
req=$(sh "${WAKE_REQUESTS:-$here/work-requests.sh}" 2>/dev/null)
[ -n "$fix" ] && { echo "fix agents owed: $(printf '%s' "$fix" | sed 's/^fix-agent //' | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"; req="$fix
$req"; }
d=$(wake_decision "$out" "$req")
kind=$(printf '%s' "$d" | cut -f1)
why=$(printf '%s' "$d" | cut -f2)
if [ "$kind" = start ]; then echo "start: $why"; else echo "nothing: $why"; fi
# A round proposed again and again without starting is named as a stall, carrying the wake's own reason, once
# three wakes running have found the same round and started nothing (specs/023-drive-on-work, "A round
# proposed again and again without starting shows as a stall", #2342). The count lives on the drive issue
# itself, the way wake_fix_asked_comment already keeps a pull request's own state between separate runs.
# The issue and its prior count were already read above, before the approval ran (#2513); they are not
# read a second time here.
if [ -n "$wc_issue" ]; then
  started=no; [ "$kind" = start ] && started=yes
  newcount=$(wake_repeat_count "$pk" "$pc" "$rk" "$started")
  if [ "$newcount" != "$pc" ] || [ "$rk" != "$pk" ]; then
    gh api -X POST "repos/{owner}/{repo}/issues/$wc_issue/comments" -f "body=$(wake_repeat_comment "$rk" "$newcount")" >/dev/null 2>&1
  fi
  note=$(wake_repeat_note "$newcount" "$why")
  if [ -n "$note" ]; then
    echo "stall: $note"
    if [ -f .scratch/drive/round.txt ] && ! grep -q '^stall:' .scratch/drive/round.txt 2>/dev/null; then
      printf 'stall: %s\n' "$note" >> .scratch/drive/round.txt
      wc_areas=.claude/areas.txt; [ -f "$wc_areas" ] || wc_areas=.scratch/drive/areas-guessed.txt
      sh "$here/publish-round.sh" --issue "$wc_issue" --areas "$wc_areas" .scratch/drive/round.txt >/dev/null 2>&1
    fi
  fi
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  if [ "$kind" = start ]; then echo "start=yes" >> "$GITHUB_OUTPUT"; else echo "start=no" >> "$GITHUB_OUTPUT"; fi
  echo "why=$why" >> "$GITHUB_OUTPUT"
fi
exit 0
