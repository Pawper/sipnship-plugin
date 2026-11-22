#!/bin/sh
# An issue In progress whose claim's starter run has already ended, with no open pull request naming it, is
# never really being worked (#2328): a wake that dispatches an agent and ends its own turn before that agent
# pushes anything leaves exactly this behind, and a reader that only checks the State label would report
# "nothing to do" for up to four hours, the claim's own TTL. This pass finds such issues and frees them: one
# "Claim released" comment naming why, the State label back to Ready, and one line saying so, so the next
# round can pick the issue up again rather than waiting it out.
# Safe to run again: an issue with no run-naming claim (a person's or the desktop app's own starter, which
# this never touches), one whose run has not ended, or one an open pull request already closes, is left
# exactly as it is.
#
# CLAIM_STALE_OWN_RUN, when set, names this very run (GITHUB_RUN_ID): a claim naming it is read as ended with
# no REST call to ask, since a step placed after the one that dispatched the agent (drive-wake.yml, "Free any
# agent this tick left running", if: always()) already knows its own run has not finished, only that step has
# — freeing the issue the same job, the same minute, rather than waiting for a run-completed read on a later
# tick (#2328).
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/claim-stale.sh" [--apply]
here=$(dirname "$0")
. "$here/claim-lib.sh"
apply=no; [ "${1:-}" = --apply ] && apply=yes
command -v gh >/dev/null 2>&1 || { echo "claim-stale: gh is not available; nothing to check."; exit 0; }
ttl=${CLAIM_TTL:-14400}

# Every open issue carrying either label form of state:in-progress, issues only (never a pull request).
inprog=$(gh api "repos/{owner}/{repo}/issues?state=open&per_page=100" --jq '.[] | select(.pull_request == null) | select([.labels[].name] | any(. == "state:in-progress" or . == "state: in-progress")) | .number' 2>/dev/null)
[ -n "$inprog" ] || { echo "claim-stale: no issue is In progress."; exit 0; }
closes=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '[.[].body // "" | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]][]] | join(",")' 2>/dev/null)

found=0
for n in $inprog; do
  case ",$closes," in *",$n,"*) continue ;; esac
  comments=$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100&sort=created&direction=desc" --jq '[.[] | select(.body | test("^Claim(: | released: )"))] | reverse | .[] | [.id, (.created_at | fromdateiso8601), (.body | split("\n")[0]), ((.body | capture("(?m)^Run: (?<r>[0-9]+)$")?.r) // "")] | @tsv' 2>/dev/null)
  runs=$(claim_run_ids "$comments")
  [ -n "$runs" ] || continue
  rawwin=$(claim_winner "$comments" "$(date +%s)" "$ttl" "")
  [ -n "$rawwin" ] || continue
  ended=""
  for r in $runs; do
    if [ -n "${CLAIM_STALE_OWN_RUN:-}" ] && [ "$r" = "$CLAIM_STALE_OWN_RUN" ]; then ended="$ended
$r"; continue; fi
    st=$(gh api "repos/{owner}/{repo}/actions/runs/$r" --jq .status 2>/dev/null)
    if [ "$st" = completed ]; then ended="$ended
$r"; fi
  done
  win=$(claim_winner "$comments" "$(date +%s)" "$ttl" "$ended")
  [ -z "$win" ] || continue
  found=1
  if [ "$apply" != yes ]; then
    echo "claim-stale: issue #$n is In progress under a claim ($rawwin) whose run has ended, with no open pull request; it would be freed, back to Ready."
    continue
  fi
  gh api -X POST "repos/{owner}/{repo}/issues/$n/comments" -f "body=Claim released: $rawwin
The run that made this claim has ended, with nothing pushed; freed by the next tick instead of waiting out its four-hour claim (#2328)." >/dev/null 2>&1
  have=$(gh api "repos/{owner}/{repo}/issues/$n/labels" --jq '.[].name' 2>/dev/null)
  form="state:ready"
  printf '%s\n' "$have" | grep -q '^state: ' && form="state: ready"
  printf '%s\n' "$have" | grep -E '^state: ?' | while IFS= read -r l; do
    enc=$(printf '%s' "$l" | sed 's/:/%3A/g;s/ /%20/g')
    gh api -X DELETE "repos/{owner}/{repo}/issues/$n/labels/$enc" >/dev/null 2>&1
  done
  if gh api -X POST "repos/{owner}/{repo}/issues/$n/labels" -f "labels[]=$form" >/dev/null 2>&1; then
    gh api -X POST "repos/{owner}/{repo}/issues/$n/comments" -f "body=Freed: the wake that claimed this issue ended with its agent still working, and that run has since finished with nothing pushed. Nothing is on it now; back to Ready for the next round." >/dev/null 2>&1
    echo "claim-stale: freed issue #$n (claim $rawwin, its run ended, no open pull request); set back to Ready."
  else
    echo "claim-stale: released the claim on #$n, but could not set it back to Ready; set it with scripts/state.sh."
  fi
done
[ "$found" = 1 ] || echo "claim-stale: every In progress issue either has an open pull request, a live claim, or no claim naming a run."
exit 0
