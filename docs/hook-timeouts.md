# When a hook runs out of time

A hook that does not answer within its limit is stopped by Claude Code and the
action goes ahead unchecked. Each hook runs through `hooks/scripts/hook-timed.sh`,
which writes a start line and an end line (name, limit, milliseconds) to
`.scratch/hooks/timing.log` in the project, on this machine only. A hook killed
for running out of time leaves a start line with no end line. The session brief
names any hook that ran past half its limit in the last day.

The two hooks that read the network (the API budget check and the ask check)
have a short bound of their own, `HOOK_NET_SECONDS` (4 and 5 seconds, inside a
10 second limit). When the bound is hit the read is stopped, a `bound` line goes
to the timing log, and the hook decides from what it has: a cached budget
reading if there is one, otherwise it lets the call through.

| Hook | Limit | If it times out | What catches the rule afterwards |
|---|---|---|---|
| block-rule-switch | 10 s | A write to a rule switch goes through | Nothing automatic; the switch file is in git and shows on the pull request |
| block-loose-ends | 10 s | A pull request closes with no comment, a detached worktree is added, or a shell call with no description runs | The nightly audit reports branches left after their pull request ended; a shell call with no description has no later check |
| block-delete | 10 s | A delete goes through before the fact | The `delete-check` step fails a pull request that deletes a tracked file; an untracked file is not covered |
| block-force-push | 10 s | A forced push goes through | The branch ruleset on the repository (Block force pushes) |
| block-full-test-sweep | 10 s | A bare full test command runs | Nothing; it costs time, and the pull request's per-file run is unaffected |
| block-generated-page | 10 s | A direct edit of a generated page is written | The generated-page check in CI fails when the page is stale |
| require-state-label | 10 s (its own read: 5 s) | An issue is filed without a State label, or set to waiting on the owner without a good ask | The state-label workflow and the nightly audit name an issue with no State; a bad ask is named by the ask audit |
| require-batch-merge | 10 s | A direct merge goes through | The queue is the only merge path and refuses what is not ready; a direct merge is refused by the branch rules |
| require-gh-budget | 10 s (its own read: 4 s) | A GraphQL call goes through on a spent budget | Nothing; GitHub refuses the call itself and the brief shows the budget |
| require-local-checks | 90 s | A push goes up without the quick checks | The same steps run in the `checks` CI job on the pull request |
| require-agent-model | 10 s | An agent is dispatched without a fitting model | Nothing; a dispatch happens only inside a session |
| require-clean-worktree | 20 s | A task finishes with files left in its worktree | The merge queue refuses a pull request whose worktree is not clean |
| watch-resolution | 5 to 6 s | A refusal's outcome is not noted for the console | Nothing needed; the note is only for the console's feed |
| session-brief | 20 s | No brief is printed; the session starts without it | `sh scripts/gh-budget.sh` and `board-now.sh` give the same facts on demand |
| session-sample | 5 to 10 s | A sample of the session is not taken | Nothing needed |
| wake-start | 5 to 10 s | This machine's connection is not started, so a press on the dashboard waits for the drive's next look | Nothing needed; the next turn's end starts it, and the timed drive starts the round meanwhile |
