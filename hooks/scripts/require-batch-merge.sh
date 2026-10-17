#!/bin/sh
# PreToolUse hook for Bash: every merge goes through the project's queue.
#
#   - A direct `gh pr merge` is refused when the project has the queue
#     script, because the queue is what checks the folder, waits for a quiet
#     main, batches, cleans up the worktree and records flaky tests. One
#     rule in CLAUDE.md is easy to miss; a refusal is not.
#   - More than two PRs through merge-queue.sh need --batch, --serial or
#     --drain: the batch is the unit of merging; serial is the exception
#     you name.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0

root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
if [ -n "$root" ] && [ -f "$root/scripts/ci/merge-queue.sh" ] && [ -n "$(direct_merge_reason "$cmd")" ]; then
  printf '%s\n' "Blocked \`gh pr merge\` because this project merges through its queue, which checks the folder, waits for a quiet main and batches; run \`sh scripts/ci/merge-queue.sh --drain\` to merge everything that is green, or \`sh scripts/ci/merge-queue.sh --serial PR\` for one pull request." >&2
  exit 2
fi

hit=$(batch_merge_reason "$cmd")
[ -n "$hit" ] || exit 0

printf '%s\n' "Blocked merging $hit pull requests one at a time because merging must not take longer than the development did; run \`merge-queue.sh --batch PR...\` to merge them in one integration run, \`--drain\` to merge everything green, or \`--serial\` if these must land alone." >&2
exit 2
