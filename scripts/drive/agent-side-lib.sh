#!/bin/sh
# A freed tick's agent work is never only on the runner's disk (#2336, left over from #2328, specs/023-
# drive-on-work, "A claim whose starter has ended is not a live claim"): when claim-stale.sh frees an issue
# whose worktree still has commits the remote does not have, those commits are pushed to a side branch before
# the workspace is cleaned up, named in the claim's release comment so the next agent starts from it instead
# of from scratch. Pure text helpers here, the same way fix-side-lib.sh's are; claim-stale.sh runs the real
# git and gh.

# agentside_branch ISSUE: the side branch's name, matching the fixside/pr-N convention. Never issue-N (or a
# prefix of it), so neither claim.sh nor the queue ever reads it as the issue's own live work.
agentside_branch() { printf 'agentside/issue-%s\n' "$1"; }

# agentside_worktree_path ISSUE WORKTREES: WORKTREES is `git worktree list --porcelain` output (one or more
# "worktree PATH" lines, each followed eventually by its own "branch refs/heads/NAME" line). Prints the path
# of the one worktree whose branch is named for ISSUE, the convention claim_busy_reason already reads a
# branch by ("issue-N" itself, or "issue-N-..." for a bundle or a renamed branch); nothing when none matches,
# or the worktree is detached (no branch line).
agentside_worktree_path() {
  printf '%s\n' "$2" | tr -d '\r' | awk -v n="$1" '
    /^worktree / { path = substr($0, 10); next }
    /^branch / {
      b = substr($0, 8); sub(/^refs\/heads\//, "", b)
      if (path != "" && (b == "issue-" n || index(b, "issue-" n "-") == 1)) { print path; exit }
      path = ""
    }'
}

# agentside_rescue_note ISSUE BRANCH COUNT: the lines added to the claim's release comment when real work was
# pushed to a side branch, naming it so the next agent starts from it instead of from scratch. The first line
# is a marker a reader can grep for; COUNT is how many commits were rescued.
agentside_rescue_note() {
  asn_s=""; [ "${3:-1}" = 1 ] || asn_s=s
  printf 'Side branch: %s | %s commit%s rescued\n' "$2" "${3:-1}" "$asn_s"
  printf "The agent's work was not lost: %s commit%s this issue's worktree had made, not yet on GitHub, were pushed to %s before the workspace is cleaned up. The next agent starts from it instead of from scratch.\n" "${3:-1}" "$asn_s" "$2"
}
