#!/bin/sh
# Claim an issue before an agent starts on it, so a second starter sees the first (specs/023-drive-on-work).
# Every starter calls this first: the scheduled drive, the wake, a Start now press, the agent itself.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/claim.sh" ISSUE claim [TOKEN]   claim it; prints "claimed TOKEN" (exit 0) or "taken: WHY" (exit 1)
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/claim.sh" ISSUE check [TOKEN]   only look: "free" (exit 0) or "taken: WHY" (exit 1); an agent's first step, with the token it was given (its own claim is no reason to stop)
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/claim.sh" ISSUE release TOKEN [WHY]   end the claim, when the agent is done; kept ("kept: ...", exit 1) while an open pull request that closes the issue has checks still running, unless WHY (or CLAIM_RELEASE_REASON) says plainly why the agent cannot stay, which is left on the pull request (#2445)
# An issue is taken when it is closed, an open pull request closes it, a branch named for it exists, or
# another live claim (under four hours old; CLAIM_TTL seconds, unless its starter's run has already
# completed, #2328) is older than this one. REST only.
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/../../hooks/scripts/board-checks-lib.sh"
. "$here/round-state-lib.sh"
. "$here/claim-lib.sh"
. "$here/stale-lib.sh"
# A token of the drive's own, when the owner has set one up (as the queue
# does, QUEUE_MERGE_TOKEN): every starter calls this first, the agent
# itself included, so this one line gives an identity of its own to both
# (#2863).
[ -z "${SIPNSHIP_DRIVE_TOKEN:-}" ] || export GH_TOKEN="$SIPNSHIP_DRIVE_TOKEN"
type gitb >/dev/null 2>&1 || gitb() { if command -v timeout >/dev/null 2>&1; then timeout -k 5 "${GIT_BOUND_SECONDS:-120}" git "$@"; else git "$@"; fi; }
usage() { echo "usage: claim.sh ISSUE claim [TOKEN] | check | release TOKEN" >&2; exit 2; }
case "${1:-}" in ''|*[!0-9]*) usage ;; esac
issue=$1; mode=${2:-}
ttl=${CLAIM_TTL:-14400}
command -v gh >/dev/null 2>&1 || { echo "taken: gh is not available, so the claim cannot be checked"; exit 1; }

# The claim and release comments, oldest first: ID, epoch second, first line, and the run its own second
# line names ("Run: ID", left by this script when GITHUB_RUN_ID is set, so a reader can tell a claim whose
# starter has ended apart from one still running, #2328).
claim_comments() {
  gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100&sort=created&direction=desc" --jq '[.[] | select(.body | test("^Claim(: | released: )"))] | reverse | .[] | [.id, (.created_at | fromdateiso8601), (.body | split("\n")[0]), ((.body | capture("(?m)^Run: (?<r>[0-9]+)$")?.r) // "")] | @tsv' 2>/dev/null
}
# Which of COMMENTS' named runs have completed, over REST, one call per distinct run (#2328): a starter's run
# that has ended means nobody is really on the issue, whatever the four-hour TTL still allows.
claim_ended_runs() {
  for cr_r in $(claim_run_ids "$1"); do
    cr_st=$(gh api "repos/{owner}/{repo}/actions/runs/$cr_r" --jq .status 2>/dev/null)
    if [ "$cr_st" = completed ]; then echo "$cr_r"; fi
  done
}
# Why the issue already has work, or nothing.
claim_busy() {
  state=$(gh api "repos/{owner}/{repo}/issues/$issue" --jq .state 2>/dev/null) || { echo "the issue could not be read"; return 0; }
  [ "$state" = open ] || { echo "the issue is not open"; return 0; }
  pulls=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, ((.body // "") | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]] | join(","))] | @tsv' 2>/dev/null)
  branches=$( { gitb ls-remote --heads origin "issue-$issue" "issue-$issue-*" "fix-$issue" 2>/dev/null | sed 's#.*refs/heads/##'; git branch --list "issue-$issue" "issue-$issue-*" "fix-$issue" 2>/dev/null | sed 's/^[*+ ]*//'; } )
  # Every pull request of this branch, any state (a squash merge leaves no commit of the branch's own that main lacks,
  # so a branch whose only pull requests ended is free of its claim, whatever it is named, #2259).
  pr_branches=$(gh api "repos/{owner}/{repo}/pulls?state=all&per_page=100" --jq '.[] | [.head.ref, .state] | @tsv' 2>/dev/null)
  claim_busy_reason "$issue" "$pulls" "$branches" "$pr_branches"
}

case "$mode" in
  check)
    why=$(claim_busy)
    comments=$(claim_comments)
    win=$(claim_winner "$comments" "$(date +%s)" "$ttl" "$(claim_ended_runs "$comments")")
    # A branch named for the issue is the normal result of the starter's own claim (claim, then worktree, then
    # the agent's check), so when the live claim carries the token given, the branch is explained and no reason to
    # stop; a closed issue or an open pull request still is (#2420).
    case "$why" in "a branch ("*) [ -n "${3:-}" ] && [ "$win" = "$3" ] && why="" ;; esac
    [ -z "$why" ] || { echo "taken: $why"; exit 1; }
    [ -z "$win" ] || [ "$win" = "${3:-}" ] || { echo "taken: another starter claimed it ($win)"; exit 1; }
    echo free ;;
  claim)
    token=${3:-$$-$(date +%s)}
    why=$(claim_busy)
    [ -z "$why" ] || { echo "taken: $why"; exit 1; }
    comments=$(claim_comments)
    win=$(claim_winner "$comments" "$(date +%s)" "$ttl" "$(claim_ended_runs "$comments")")
    [ -z "$win" ] || { echo "taken: another starter claimed it ($win)"; exit 1; }
    # The run that makes this claim, so a later reader can tell it apart from one whose starter ended (#2328);
    # empty outside GitHub Actions (an interactive session, the desktop app), which the four-hour TTL still governs.
    run_line=""
    [ -n "${GITHUB_RUN_ID:-}" ] && run_line="
Run: $GITHUB_RUN_ID"
    mine=$(gh api -X POST "repos/{owner}/{repo}/issues/$issue/comments" -f "body=Claim: $token
An agent is about to start on this issue; nothing else should start one.${run_line}" --jq .id 2>/dev/null) || { echo "taken: the claim could not be posted"; exit 1; }
    comments=$(claim_comments)
    win=$(claim_winner "$comments" "$(date +%s)" "$ttl" "$(claim_ended_runs "$comments")")
    if [ "$win" = "$token" ]; then echo "claimed $token"; exit 0; fi
    gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$mine" -f "body=Claim released: $token
Another starter claimed this issue first." >/dev/null 2>&1
    echo "taken: another starter claimed it first (${win:-unknown})"; exit 1 ;;
  release)
    [ -n "${3:-}" ] || usage
    # An agent that opened a change stays with it until its checks have ended, or says plainly why it cannot (#2445): a claim freed on
    # a change whose checks are still running leaves a red one nobody is on.
    rel_why=${4:-${CLAIM_RELEASE_REASON:-}}
    rel_pr=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, .head.sha, ((.body // "") | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]] | join(","))] | @tsv' 2>/dev/null | tr -d '\r' | awk -F'\t' -v n="$issue" '{ k = split($3, a, ","); for (i = 1; i <= k; i++) if (a[i] == n) { print $1 "\t" $2; exit } }')
    if [ -n "$rel_pr" ]; then
      rel_n=$(printf '%s' "$rel_pr" | cut -f1); rel_sha=$(printf '%s' "$rel_pr" | cut -f2)
      rel_pending=$(checks_pending "$(head_check_lines "$rel_sha")")
      rel_say=$(claim_release_hold "$rel_n" "$rel_pending" "$rel_why")
      if [ -n "$rel_say" ]; then echo "$rel_say"; exit 1; fi
      if [ "$rel_pending" = yes ] && [ -n "$rel_why" ]; then
        gh api -X POST "repos/{owner}/{repo}/issues/$rel_n/comments" -f "body=The agent that opened this change is leaving before its checks ended, because: $rel_why" >/dev/null 2>&1
      fi
    fi
    # The State label is set here, by the script, not left for the agent to remember (#2441): closed stays
    # closed; open with a change that closes it (rel_pr above) stays In progress; open with nothing that closes
    # it goes back to Ready, whatever note of what is left the agent already left as a comment.
    rel_pr_num=$(printf '%s' "$rel_pr" | cut -f1)
    rel_info=$(gh api "repos/{owner}/{repo}/issues/$issue" --jq '[.state, (.labels | map(.name) | join(","))] | @tsv' 2>/dev/null)
    rel_slug=$(claim_release_slug "$(printf '%s' "$rel_info" | cut -f1)" "$rel_pr_num")
    if [ -n "$rel_slug" ]; then
      stale_labels_json "$(printf '%s' "$rel_info" | cut -f2 | tr ',' '\n')" "$rel_slug" | gh api -X PUT "repos/{owner}/{repo}/issues/$issue/labels" --input - >/dev/null 2>&1
    fi
    gh api -X POST "repos/{owner}/{repo}/issues/$issue/comments" -f "body=Claim released: $3
The agent is done with this issue." >/dev/null 2>&1 && echo "released $3" || { echo "could not release $3" >&2; exit 1; } ;;
  *) usage ;;
esac
