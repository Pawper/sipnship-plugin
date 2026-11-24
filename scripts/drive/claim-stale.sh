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
. "$here/agent-side-lib.sh"
apply=no; [ "${1:-}" = --apply ] && apply=yes
command -v gh >/dev/null 2>&1 || { echo "claim-stale: gh is not available; nothing to check."; exit 0; }
ttl=${CLAIM_TTL:-14400}

# Before an issue is freed, real work its agent already made is rescued to a side branch, so it is not lost
# once the workspace is cleaned up (#2336, left over from #2328; #2465 widens this from commits not yet on
# GitHub to files the agent changed or created but never committed at all, which until now stayed in a
# folder nothing read again). Nothing when git cannot list worktrees, none matches the issue, or it has
# nothing to rescue, committed or not. Prints the branch, how many commits and how many files on success;
# nothing, and changes nothing, when there is no work to rescue.
type gitb >/dev/null 2>&1 || gitb() { if command -v timeout >/dev/null 2>&1; then timeout -k 5 "${GIT_BOUND_SECONDS:-120}" git "$@"; else git "$@"; fi; }

# Uncommitted or untracked work the agent made, committed as one commit plainly marked as not its own
# (agentside_wip_message), before it is counted and pushed as if it had always been there. `git add -A`
# already skips everything the worktree's own .gitignore excludes (.scratch, build output); a path that
# looks like a secret by its name alone (agentside_looks_secret) is unstaged again before the commit is
# made, so it is never included, left exactly as it was in the worktree. Nothing when there is nothing to
# commit, or nothing is left once a secret-looking path is set aside.
commit_uncommitted() {
  wt=$1
  gitb -C "$wt" add -A -- . >/dev/null 2>&1
  staged=$(gitb -C "$wt" diff --cached --name-only 2>/dev/null)
  [ -n "$staged" ] || return 0
  printf '%s\n' "$staged" | while IFS= read -r f; do
    agentside_looks_secret "$f" && gitb -C "$wt" reset -q -- "$f" >/dev/null 2>&1
  done
  staged=$(gitb -C "$wt" diff --cached --name-only 2>/dev/null)
  [ -n "$staged" ] || return 0
  agentside_wip_message | gitb -C "$wt" commit -q -F - >/dev/null 2>&1
}

rescue_agent_side() {
  command -v git >/dev/null 2>&1 || return 0
  wt=$(gitb worktree list --porcelain 2>/dev/null); wt=$(agentside_worktree_path "$1" "$wt")
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  branch=$(git -C "$wt" branch --show-current 2>/dev/null)
  [ -n "$branch" ] || return 0
  commit_uncommitted "$wt"
  gitb -C "$wt" fetch origin --quiet 2>/dev/null
  unpushed=$(gitb -C "$wt" rev-list "$branch" --not --remotes=origin 2>/dev/null)
  [ -n "$unpushed" ] || return 0
  count=$(printf '%s\n' "$unpushed" | grep -c .)
  oldest=$(printf '%s\n' "$unpushed" | tail -n1)
  files=$(gitb -C "$wt" diff --name-only "$oldest"^ "$branch" 2>/dev/null | grep -c .)
  side=$(agentside_branch "$1")
  gitb -C "$wt" push origin "$branch:refs/heads/$side" >/dev/null 2>&1 || return 0
  printf '%s\t%s\t%s\n' "$side" "$count" "$files"
}

# Every open issue carrying either label form of state:in-progress, issues only (never a pull request).
# Read by label, not by the first page of open issues: a project with more than a hundred open issues
# kept its In progress ones past the first page, and this pass saw none of them (#2561).
inprog=$( { gh api "repos/{owner}/{repo}/issues?state=open&labels=state:in-progress&per_page=100" --jq '.[] | select(.pull_request == null) | .number' 2>/dev/null; gh api "repos/{owner}/{repo}/issues?state=open&labels=state:%20in-progress&per_page=100" --jq '.[] | select(.pull_request == null) | .number' 2>/dev/null; } | sort -un)
[ -n "$inprog" ] || { echo "claim-stale: no issue is In progress."; exit 0; }
closes=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '[.[].body // "" | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]][]] | join(",")' 2>/dev/null)

found=0; own_freed=""
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
  # A claim made by this very run, on an issue with no branch and no open pull request: this tick claimed it and built nothing (#2561).
  own=no
  if [ -n "${CLAIM_STALE_OWN_RUN:-}" ] && printf '%s\n' "$comments" | tr -d '\r' | awk -F'\t' -v r="$CLAIM_STALE_OWN_RUN" '$4 == r { f = 1 } END { exit !f }'; then own=yes; fi
  if [ "$apply" != yes ]; then
    echo "claim-stale: issue #$n is In progress under a claim ($rawwin) whose run has ended, with no open pull request; it would be freed, back to Ready."
    continue
  fi
  rescued=$(rescue_agent_side "$n")
  rescue_said=""; freed_said=" Nothing is on it now; back to Ready for the next round."
  released_words="The run that made this claim has ended, with nothing pushed; freed by the next tick instead of waiting out its four-hour claim (#2328)."
  if [ -n "$rescued" ]; then
    rb=$(printf '%s' "$rescued" | cut -f1); rc=$(printf '%s' "$rescued" | cut -f2); rf=$(printf '%s' "$rescued" | cut -f3)
    rescue_said="
$(agentside_rescue_note "$n" "$rb" "$rc" "$rf")"
    released_words="The run that made this claim has ended; freed by the next tick instead of waiting out its four-hour claim (#2328)."
    freed_said=" Its real work was not lost, pushed to $rb; back to Ready for the next round, which can start from it."
  fi
  if [ "$own" = yes ] && [ -z "$rescued" ]; then
    released_words="This drive tick claimed the issue and ended without building anything, so the claim is freed before the tick ends (#2561)."
    freed_said=" Nothing was built and nothing is on it; it is back to Ready, and the next round can pick it up."
  fi
  gh api -X POST "repos/{owner}/{repo}/issues/$n/comments" -f "body=Claim released: $rawwin
${released_words}${rescue_said}" >/dev/null 2>&1
  have=$(gh api "repos/{owner}/{repo}/issues/$n/labels" --jq '.[].name' 2>/dev/null)
  form="state:ready"
  printf '%s\n' "$have" | grep -q '^state: ' && form="state: ready"
  printf '%s\n' "$have" | grep -E '^state: ?' | while IFS= read -r l; do
    enc=$(printf '%s' "$l" | sed 's/:/%3A/g;s/ /%20/g')
    gh api -X DELETE "repos/{owner}/{repo}/issues/$n/labels/$enc" >/dev/null 2>&1
  done
  if gh api -X POST "repos/{owner}/{repo}/issues/$n/labels" -f "labels[]=$form" >/dev/null 2>&1; then
    if [ "$own" = yes ] && [ -z "$rescued" ]; then
      own_freed="$own_freed #$n"
      gh api -X POST "repos/{owner}/{repo}/issues/$n/comments" -f "body=Freed: the drive tick that claimed this issue ended before any work was pushed, so nothing was built.${freed_said}" >/dev/null 2>&1
    else
      gh api -X POST "repos/{owner}/{repo}/issues/$n/comments" -f "body=Freed: the wake that claimed this issue ended with its agent still working, and that run has since finished.${freed_said}" >/dev/null 2>&1
    fi
    if [ -n "$rescued" ]; then
      echo "claim-stale: freed issue #$n (claim $rawwin, its run ended); rescued $rc commit(s), $rf file(s), to $rb; set back to Ready."
    else
      echo "claim-stale: freed issue #$n (claim $rawwin, its run ended, no open pull request); set back to Ready."
    fi
  else
    echo "claim-stale: released the claim on #$n, but could not set it back to Ready; set it with scripts/state.sh."
  fi
done
# A run that claimed and built nothing is not a plain success: say so where the run's summary and the drive's log read it (#2561).
if [ -n "$own_freed" ]; then
  say="This tick claimed${own_freed} and built nothing; the claims are freed and the issues are back to Ready."
  echo "claim-stale: $say"
  echo "::warning title=A tick that built nothing::$say"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### Nothing was built\n\n%s\n' "$say" >> "$GITHUB_STEP_SUMMARY"
fi
[ "$found" = 1 ] || echo "claim-stale: every In progress issue either has an open pull request, a live claim, or no claim naming a run."
exit 0
