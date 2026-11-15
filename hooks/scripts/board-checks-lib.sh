#!/bin/sh
# Check results for a head commit without the Checks permission, which a
# fine-grained personal access token cannot have (GitHub does not offer it).
# The drive reads checks from check runs when it may; when GitHub refuses
# those it reads the Actions API (the workflow runs of the commit) and the
# commit statuses, which a token with Actions and Commit statuses read can
# see. Sourced by board-now.sh and by the drive's plan.

# token_refusal TEXT: "yes" when GitHub's message says the token may not read
# the thing asked for (a field or an endpoint), as opposed to a rate limit or
# a signed-out gh.
token_refusal() {
  case "$1" in
    *"Resource not accessible by personal access token"*|*"Resource not accessible by integration"*|*"Resource not accessible by"*) echo yes ;;
    *) echo no ;;
  esac
}

# status_lines STATE...: commit statuses, one "pending", "success", "failure"
# or "error" a line, as the "STATUS<TAB>CONCLUSION" lines check runs give:
# pending is still running, success is done and passed, the rest failed.
status_lines() {
  printf '%s\n' "$1" | tr -d '\r' | while IFS= read -r sl_s; do
    case "$sl_s" in
      pending) printf 'in_progress\t\n' ;;
      success) printf 'completed\tsuccess\n' ;;
      failure|error) printf 'completed\tfailure\n' ;;
    esac
  done
}

# rollup_of LINES: the rollup word for one commit from "STATUS<TAB>CONCLUSION"
# lines: FAILURE when a run failed (even if others still run, as GitHub's
# rollup does), PENDING while any has not completed, SUCCESS when all are done
# and none failed, NONE with no lines.
rollup_of() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF == 0 || $1 == "" { next }
    { n++ }
    $1 != "completed" { open = 1 }
    $2 == "failure" || $2 == "timed_out" || $2 == "startup_failure" || $2 == "cancelled" || $2 == "action_required" { bad = 1 }
    END { print (n == 0) ? "NONE" : bad ? "FAILURE" : open ? "PENDING" : "SUCCESS" }'
}

# head_check_lines SHA: "STATUS<TAB>CONCLUSION" for the commit's checks. Check
# runs first; when GitHub refuses them, the workflow runs for the commit and
# its commit statuses (two REST calls, no Checks permission).
head_check_lines() {
  hc_out=$(gh api "repos/{owner}/{repo}/commits/$1/check-runs?per_page=100" --jq '.check_runs[] | [.status, (.conclusion // "")] | @tsv' 2>/dev/null) && { printf '%s\n' "$hc_out" | tr -d '\r'; return 0; }
  gh api "repos/{owner}/{repo}/actions/runs?head_sha=$1&per_page=100" --jq '.workflow_runs[] | [.status, (.conclusion // "")] | @tsv' 2>/dev/null | tr -d '\r'
  status_lines "$(gh api "repos/{owner}/{repo}/commits/$1/status" --jq '.statuses[].state' 2>/dev/null | tr -d '\r')"
}

# pr_rollups FACTS: board-now's pull request lines with the head commit's sha
# in the fourth field, the rollup put in its place.
pr_rollups() {
  pr_tab=$(printf '\t')
  printf '%s\n' "$1" | while IFS= read -r pr_l; do
    case "$pr_l" in
      pr"$pr_tab"*)
        pr_sha=$(printf '%s' "$pr_l" | cut -f4)
        printf '%s\n' "$pr_l" | awk -F'\t' -v OFS='\t' -v r="$(rollup_of "$(head_check_lines "$pr_sha")")" '{ $4 = r; print }' ;;
      *) printf '%s\n' "$pr_l" ;;
    esac
  done
}
