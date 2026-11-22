#!/bin/sh
# Claim an issue before an agent starts on it, so a second starter sees the first (specs/023-drive-on-work).
# Every starter calls this first: the scheduled drive, the wake, a Start now press, the agent itself.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/claim.sh" ISSUE claim [TOKEN]   claim it; prints "claimed TOKEN" (exit 0) or "taken: WHY" (exit 1)
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/claim.sh" ISSUE check [TOKEN]   only look: "free" (exit 0) or "taken: WHY" (exit 1); an agent's first step, with the token it was given (its own claim is no reason to stop)
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/claim.sh" ISSUE release TOKEN   end the claim, when the agent is done
# An issue is taken when it is closed, an open pull request closes it, a branch named for it exists, or
# another live claim (under four hours old; CLAIM_TTL seconds) is older than this one. REST only.
here=$(dirname "$0")
. "$here/claim-lib.sh"
type gitb >/dev/null 2>&1 || gitb() { if command -v timeout >/dev/null 2>&1; then timeout -k 5 "${GIT_BOUND_SECONDS:-120}" git "$@"; else git "$@"; fi; }
usage() { echo "usage: claim.sh ISSUE claim [TOKEN] | check | release TOKEN" >&2; exit 2; }
case "${1:-}" in ''|*[!0-9]*) usage ;; esac
issue=$1; mode=${2:-}
ttl=${CLAIM_TTL:-14400}
command -v gh >/dev/null 2>&1 || { echo "taken: gh is not available, so the claim cannot be checked"; exit 1; }

# The claim and release comments, oldest first: ID, epoch second, first line.
claim_comments() {
  gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100&sort=created&direction=desc" --jq '[.[] | select(.body | test("^Claim(: | released: )"))] | reverse | .[] | [.id, (.created_at | fromdateiso8601), (.body | split("\n")[0])] | @tsv' 2>/dev/null
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
    [ -z "$why" ] || { echo "taken: $why"; exit 1; }
    win=$(claim_winner "$(claim_comments)" "$(date +%s)" "$ttl")
    [ -z "$win" ] || [ "$win" = "${3:-}" ] || { echo "taken: another starter claimed it ($win)"; exit 1; }
    echo free ;;
  claim)
    token=${3:-$$-$(date +%s)}
    why=$(claim_busy)
    [ -z "$why" ] || { echo "taken: $why"; exit 1; }
    win=$(claim_winner "$(claim_comments)" "$(date +%s)" "$ttl")
    [ -z "$win" ] || { echo "taken: another starter claimed it ($win)"; exit 1; }
    mine=$(gh api -X POST "repos/{owner}/{repo}/issues/$issue/comments" -f "body=Claim: $token
An agent is about to start on this issue; nothing else should start one." --jq .id 2>/dev/null) || { echo "taken: the claim could not be posted"; exit 1; }
    win=$(claim_winner "$(claim_comments)" "$(date +%s)" "$ttl")
    if [ "$win" = "$token" ]; then echo "claimed $token"; exit 0; fi
    gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$mine" -f "body=Claim released: $token
Another starter claimed this issue first." >/dev/null 2>&1
    echo "taken: another starter claimed it first (${win:-unknown})"; exit 1 ;;
  release)
    [ -n "${3:-}" ] || usage
    gh api -X POST "repos/{owner}/{repo}/issues/$issue/comments" -f "body=Claim released: $3
The agent is done with this issue." >/dev/null 2>&1 && echo "released $3" || { echo "could not release $3" >&2; exit 1; } ;;
  *) usage ;;
esac
