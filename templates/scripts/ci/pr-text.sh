#!/bin/sh
# The pull request's live title and body, for a step of the checks job that
# reads a line from it (Spec:, Mock:, Design:, Deletes:). Live, so a re-run
# sees an edited body; the event's copy is the body as it was when the run
# started.
#   SPEC_TEXT=$(sh scripts/ci/pr-text.sh PR_NUMBER "the mock check") || exit 1
#   PR_BODY=$(sh scripts/ci/pr-text.sh --body PR_NUMBER "the delete check") || exit 1
# Three tries, a few seconds apart. When none answers it prints nothing,
# says so in the check's place (to stderr and to the check log the "Say what
# failed" step reads) and exits 1, so the step fails on the read, never on a
# line the body may well have had: reading the title alone once hid a valid
# "Mock: unchanged, ..." line and failed on the mock.
# Needs GH_TOKEN and GITHUB_REPOSITORY, as a step of the checks job has.
jq_text='.title + "\n" + (.body // "")'
if [ "${1:-}" = --body ]; then jq_text='.body // ""'; shift; fi
pr=${1:?usage: pr-text.sh [--body] PR_NUMBER CHECK_NAME}; check=${2:-this check}
tries=${PR_TEXT_TRIES:-3}; wait_s=${PR_TEXT_WAIT:-5}
repo=${GITHUB_REPOSITORY:-'{owner}/{repo}'}
i=1
while [ "$i" -le "$tries" ]; do
  if text=$(gh api "repos/$repo/pulls/$pr" --jq "$jq_text" 2>/dev/null); then
    printf '%s\n' "$text"
    exit 0
  fi
  [ "$i" -lt "$tries" ] && sleep "$wait_s"
  i=$((i + 1))
done
msg="The pull request's body could not be read from GitHub ($tries tries), so $check did not run: a line in the body that allows this change would go unseen. Nothing in the change was judged; re-run this job once GitHub answers."
log="${RUNNER_TEMP:-.scratch}/check.log"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
printf '%s\n' "$msg" > "$log" 2>/dev/null || true
printf '%s\n' "$msg" >&2
exit 1
