#!/bin/sh
# Set branch protection on main in one call, the way the merge queue needs
# it: exactly one required check, "CI passed"; "require branches to be up
# to date" off, since the queue is what keeps branches current; a pull
# request required, with no approvals; no force pushes, no deletions.
# Safe to run again; it replaces the rules with these.
#
# Usage: sh scripts/protect-main.sh [BRANCH]      (default main)
# Needs gh, signed in, with admin on the repository. A private repository
# on a free plan cannot have branch protection; the script says so.
set -e
branch=${1:-main}
out=$(gh api -X PUT "repos/{owner}/{repo}/branches/$branch/protection" --input - 2>&1 <<'EOF' || true
{
  "required_status_checks": { "strict": false, "contexts": ["CI passed"] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false
}
EOF
)
case "$out" in
  *"Upgrade to GitHub Pro"*|*"not available"*)
    echo "Branch protection is not available for this repository on its plan (a private repository on a free plan). Make the repository public, or upgrade, then run this again." >&2
    exit 1 ;;
  *"HTTP 4"*|*"HTTP 5"*|*"error"*|*"Error"*)
    printf '%s\n' "$out" >&2
    exit 1 ;;
esac
echo "Branch protection on $branch: one required check (CI passed), up-to-date off, a pull request required, no force pushes, no deletions."
