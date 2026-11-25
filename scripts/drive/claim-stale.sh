#!/bin/sh
# An issue In progress whose claim's starter run has already ended, with no open pull request naming it, is
# never really being worked (#2328): a wake that dispatches an agent and ends its own turn before that agent
# pushes anything leaves exactly this behind, and a reader that only checks the State label would report
# "nothing to do" for up to four hours, the claim's own TTL. This pass finds such issues and frees them: one
# "Claim released" comment naming why, the State label back to Ready, and one line saying so, so the next
# round can pick the issue up again rather than waiting it out.
# A claim whose run has ended is released whatever the issue's State (#2716): a drive run that claimed an issue
# in Ready, bundled it, landed the bundle's change and ended left its claim on the one issue still open, and since
# only In progress issues were read, the round waited an hour on an issue nobody was on. So every issue with a
# claim made within the TTL is read, from the repository's recent comments, besides the In progress ones. An
# issue In progress (or with no State) with no open pull request goes back to Ready as before; any other is only
# released, its State kept: a closed one, one an open pull request carries, one already in Ready, or one in
# another State such as waiting on the builder. Each release says plainly what happened.
# Safe to run again: an issue with no run-naming claim (a person's or the desktop app's own starter, which
# this never touches), or one whose run has not ended, is left exactly as it is.
#
# CLAIM_STALE_OWN_RUN, when set, names this very run (GITHUB_RUN_ID): a claim naming it is read as ended with
# no REST call to ask, since a step placed after the one that dispatched the agent (drive-wake.yml, "Free any
# agent this tick left running", if: always()) already knows its own run has not finished, only that step has
# — freeing the issue the same job, the same minute, rather than waiting for a run-completed read on a later
# tick (#2328). So a run that ends releases every claim it made, whatever happened to each issue (#2716).
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

# Whether run R has ended: this very run, by name; any other by one REST read, asked once per run per pass.
ended_seen=" "; live_seen=" "
run_ended() {
  if [ -n "${CLAIM_STALE_OWN_RUN:-}" ] && [ "$1" = "$CLAIM_STALE_OWN_RUN" ]; then return 0; fi
  case "$ended_seen" in *" $1 "*) return 0 ;; esac
  case "$live_seen" in *" $1 "*) return 1 ;; esac
  if [ "$(gh api "repos/{owner}/{repo}/actions/runs/$1" --jq .status 2>/dev/null)" = completed ]; then ended_seen="$ended_seen$1 "; return 0; fi
  live_seen="$live_seen$1 "; return 1
}

# Every open issue carrying either label form of state:in-progress, issues only (never a pull request).
# Read by label, not by the first page of open issues: a project with more than a hundred open issues
# kept its In progress ones past the first page, and this pass saw none of them (#2561).
inprog=$( { gh api "repos/{owner}/{repo}/issues?state=open&labels=state:in-progress&per_page=100" --jq '.[] | select(.pull_request == null) | .number' 2>/dev/null; gh api "repos/{owner}/{repo}/issues?state=open&labels=state:%20in-progress&per_page=100" --jq '.[] | select(.pull_request == null) | .number' 2>/dev/null; } | sort -un)
# Every issue, open or closed and whatever its State, with a claim made within the TTL (#2716): an older claim
# is not live on its own word, so nothing older can hold an issue.
since_epoch=$(( $(date +%s) - ttl ))
since=$(date -u -d "@$since_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$since_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
claimed=""
[ -z "$since" ] || claimed=$(gh api --paginate "repos/{owner}/{repo}/issues/comments?since=$since&per_page=100" --jq '.[] | select(.body | test("^Claim: ")) | .issue_url | split("/") | last' 2>/dev/null)
cands=$(printf '%s\n%s\n' "$inprog" "$claimed" | tr -d '\r' | grep -E '^[0-9]+$' | sort -un)
[ -n "$cands" ] || { echo "claim-stale: no issue is In progress or holds a recent claim."; exit 0; }
# "PR<TAB>ISSUES" a line, ISSUES the comma-separated numbers each open pull request closes.
pulls=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, ([.body // "" | scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]] | join(","))] | @tsv' 2>/dev/null)

found=0; own_freed=""; own_left=""; own_built=0
for n in $cands; do
  comments=$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100&sort=created&direction=desc" --jq '[.[] | select(.body | test("^Claim(: | released: )"))] | reverse | .[] | [.id, (.created_at | fromdateiso8601), (.body | split("\n")[0]), ((.body | capture("(?m)^Run: (?<r>[0-9]+)$")?.r) // "")] | @tsv' 2>/dev/null)
  runs=$(claim_run_ids "$comments")
  [ -n "$runs" ] || continue
  rawwin=$(claim_winner "$comments" "$(date +%s)" "$ttl" "")
  [ -n "$rawwin" ] || continue
  ended=""
  for r in $runs; do
    if run_ended "$r"; then ended="$ended
$r"; fi
  done
  win=$(claim_winner "$comments" "$(date +%s)" "$ttl" "$ended")
  [ -z "$win" ] || continue
  # A claim made by this very run (#2561); with no branch and no open pull request, this tick claimed it and built nothing.
  own=no
  if [ -n "${CLAIM_STALE_OWN_RUN:-}" ] && printf '%s\n' "$comments" | tr -d '\r' | awk -F'\t' -v r="$CLAIM_STALE_OWN_RUN" '$4 == r { f = 1 } END { exit !f }'; then own=yes; fi
  # Where the issue stands: closed, carried by an open pull request, In progress (or no State), Ready, or another State.
  pr=$(printf '%s\n' "$pulls" | tr -d '\r' | awk -F'\t' -v n="$n" '{ k = split($2, a, ","); for (i = 1; i <= k; i++) if (a[i] == n) { print $1; exit } }')
  case " $(printf '%s' "$inprog" | tr '\n' ' ') " in
    *" $n "*) state=open; labels="state:in-progress" ;;
    *) info=$(gh api "repos/{owner}/{repo}/issues/$n" --jq '.state + "\t" + ([.labels[].name] | join(","))' 2>/dev/null | tr -d '\r')
       state=$(printf '%s' "$info" | cut -f1); labels=$(printf '%s' "$info" | cut -f2) ;;
  esac
  [ -n "$state" ] || continue
  found=1
  kind=free; what=""
  if [ "$state" = closed ]; then kind=keep; what="it is closed, so nothing is left on it"
  elif [ -n "$pr" ]; then kind=keep; what="its open pull request #$pr carries it, so its State stays as it is"
  else
    case ",$labels," in
      *",state:in-progress,"*|*",state: in-progress,"*) ;;
      *",state:ready,"*|*",state: ready,"*) kind=ready; what="it was already in Ready, so the next round can start it" ;;
      *",state:"*|*",state: "*) kind=keep; what="its State stays as it is" ;;
    esac
  fi
  if [ "$kind" = keep ] || [ "$kind" = ready ]; then
    [ "$own" = yes ] && { [ "$state" = closed ] || [ -n "$pr" ]; } && own_built=1
    if [ "$apply" != yes ]; then
      echo "claim-stale: issue #$n holds a claim ($rawwin) whose run has ended; it would be released ($what)."
      continue
    fi
    rescued=""; [ "$kind" = ready ] && rescued=$(rescue_agent_side "$n")
    if [ "$state" = closed ]; then words="The run that made this claim has ended, and the issue is closed, so nothing is left on it; the claim is released (#2716)."
    elif [ -n "$pr" ]; then words="The run that made this claim has ended. Its change, pull request #$pr, is still open and carries the issue, so its State stays as it is; the claim is released (#2716)."
    elif [ "$kind" = ready ] && [ "$own" = yes ] && [ -z "$rescued" ]; then words="This drive run claimed the issue and ended with nothing pushed for it, so the claim is released before the run ends. It is in Ready, and the next round can start it (#2716)."
    elif [ "$kind" = ready ]; then words="The run that made this claim has ended, with nothing pushed for this issue, and nobody is on it. It is in Ready, and the next round can start it (#2716)."
    else words="The run that made this claim has ended, and nobody is on the issue; its State stays as it is (#2716)."
    fi
    note=""
    if [ -n "$rescued" ]; then
      rb=$(printf '%s' "$rescued" | cut -f1); rc=$(printf '%s' "$rescued" | cut -f2); rf=$(printf '%s' "$rescued" | cut -f3)
      words="The run that made this claim has ended, and nobody is on the issue. It is in Ready, and the next round can start from the work it left (#2716)."
      note="
$(agentside_rescue_note "$n" "$rb" "$rc" "$rf")"
    fi
    [ "$own" = yes ] && [ "$kind" = ready ] && [ -z "$rescued" ] && own_left="$own_left #$n"
    gh api -X POST "repos/{owner}/{repo}/issues/$n/comments" -f "body=Claim released: $rawwin
${words}${note}" >/dev/null 2>&1
    echo "claim-stale: released the claim on #$n (claim $rawwin, its run ended); $what."
    continue
  fi
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
# A run whose change landed for some of what it claimed names only what it left open (#2716).
say=""
if [ "$own_built" = 1 ]; then
  left="$own_freed$own_left"
  [ -z "$left" ] || say="This tick's change carried part of what it claimed and left${left} open with nothing pushed for it; those claims are released and the issues are in Ready."
elif [ -n "$own_freed$own_left" ]; then
  say="This tick claimed${own_freed}${own_left} and built nothing; the claims are freed and the issues are back to Ready."
fi
if [ -n "$say" ]; then
  echo "claim-stale: $say"
  [ "$own_built" = 1 ] || echo "::warning title=A tick that built nothing::$say"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### %s\n\n%s\n' "$([ "$own_built" = 1 ] && echo 'Left open' || echo 'Nothing was built')" "$say" >> "$GITHUB_STEP_SUMMARY"
fi
[ "$found" = 1 ] || echo "claim-stale: no claim is held by a run that has ended."
exit 0
