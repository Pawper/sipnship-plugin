---
name: project-drive
description: One round of proposing what a project should do next from its board and its checks, and pursuing only what a person approved. Use on a timer (/loop or a scheduled session) or by hand. It reads the state, proposes goals, stops for approval, then lands, fixes, starts and sets right only the approved ones, and interrupts a person again only for a decision.
---

# Project drive

There is no goals file. The board, the CI state and the project's own checks say what is true: an issue
labeled ready is work that could start, a green pull request is work that could land, a red one is work that
needs fixing, an audit comment is a record that drifted. This skill reads that state, proposes what to do about
it, and does nothing until a person says which parts to do. The loop is the timer; the proposal is the ask;
the audit is the check without the work; a person is interrupted for an approval and for a decision, never for
a status report.

One invocation is one round. A round is either a proposal or the pursuit of an approved proposal, decided in
step a.

## a. Read the state and the standing approval

First make sure the picture is complete. Labels and titles are not the state; bodies and comments are. Run
`/project-status`, which has light readers summarize only the items that changed since their last summary and
leaves you one line per item. On a quiet board that is no readers at all. A proposal made without it is made
from labels alone, and the plan script says so in its first line.

Then run the plan script. It gathers the facts, adds what the digest shows, and prints a numbered proposal
without doing anything:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/plan.sh" --snapshot
```

The facts: open pull requests with CI state and mergeability, issues labeled ready, in progress and waiting
on owner, the audit issue's latest comment, red-main issues, whether a queue log was written in the last two
hours, the last commits on main. If the session brief printed at session start, it already shows most of this.

Then check whether a proposal is already approved:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/approval.sh"
```

It prints the approved goals and who approved them, or one line saying why there is nothing: no drive issue,
no proposal, no reply yet, or a reply that approved nothing. This step is cheap on purpose: a timed wake that
finds nothing approved should cost a few calls and end.

## b. Propose, or pursue

**When nothing is approved and the proposal has goals:** put the proposal to a person and stop.

- In an interactive session, use the question tool: list the numbered goals as options, let the person pick
  several, and treat the picks as the approval. Go to step c in the same round.
- In a scheduled or non-interactive session, post the numbered proposal as one comment on the open issue
  labeled `drive`, starting with the word "Proposal" and ending with one line: "Reply with the numbers to
  approve, all, none, or all but some." Then end the round. The person answers on the issue; the next round
  reads it.

If the proposal is the same as the one already posted and unanswered, do not post it again; end the round in
one line. If the proposal's only lines are `defer` and `stop`, end in one line.

**When goals are approved:** pursue them in proposal order, step c, and nothing else. A goal that is no longer
true (the pull request merged by hand, the issue closed) is skipped with one line in the report.

## c. Pursue an approved goal

The goal lines and what each means:

- **`merge N` or `merge-batch N N N`.** Land through the project's queue: `sh scripts/ci/merge-queue.sh
  --serial N`, or `--batch N N N` for the batch. See `scripts/ci/QUEUE.md`. Never merge anything that is not
  green at the moment of merging, whatever the proposal said.
- **`fix-pr N`.** Read the failing check. If the cause is inside the pull request's own scope or is a
  test-environment problem (a flaky test, a cancelled run, a missing fixture), fix it on that branch and let CI
  run again. Otherwise leave one comment on the pull request naming the cause and set its issue to
  `state:blocked`.
- **`dispatch N`.** Start an agent for the issue with isolation (a worktree), the model the plugin's
  agent-model hook allows for its tier, and a brief that names the issue, the files it may touch, the rules in
  CLAUDE.md, and the pull request it must open with `Closes #N`. Set the issue to `state:in-progress` with
  `scripts/state.sh`.
- **`ask-owner N`.** A ready issue whose words touch something the owner has said is theirs. Put one comment
  on it with the question, the options and a recommendation, and set `state:waiting-on-owner`. This is a
  proposal line so the person sees it, but it is the one goal that may run without approval, since it asks
  rather than acts.
- **`fix-main N`.** Treat the red run like a red pull request on main itself: fix within scope or report the
  cause on the issue.
- **`audit TEXT`.** When the facts are plain (an issue with no State whose title says what it is, an issue
  still ready after its pull request merged), set the state or close it. When they are not plain, leave it;
  the audit will say it again tomorrow.
- **`set-ready N`.** The digest says the owner has answered an issue still labeled waiting on owner. Confirm it
  by having one reader re-read that issue, then set it to ready with `scripts/state.sh`.
- **`mark-waiting N`.** The digest says a question to the owner is open on an issue labeled ready or in
  progress. Confirm the same way, then set `state:waiting-on-owner`.
- **`restart-queue`.** Stop the queue process if one is still running, look in the main checkout for a stray
  modified tracked file and move it aside, then run the queue again.

## d. Hangups while pursuing

Three kinds, three moves, never a fourth.

1. **A fixable blocker**: a flaky test, a merge conflict, a cancelled run, a stuck queue. Fix it within the
   issue's own scope and go on.
2. **A decision only a person can make**: a price, a policy, a holder to ask, anything in the config's owner
   decisions list, anything the owner has said is theirs. One comment on the issue with the question, the
   options and a recommendation; set `state:waiting-on-owner`; move on. Never guess on a decision the owner
   has stated.
3. **Work outside the goal's own words**: file a new issue with a State label and leave it. Never widen the
   round. Widening is a new proposal, next round.

## e. Stop

A round ends when its proposal is posted, when the approved goals are done or blocked, when the ready list is
empty, or when everything left waits on a person. Say which in one line. A round also stops when it has
dispatched its agent budget (`maxAgents`, default four) or run for its minute budget (`maxMinutes`, default
ninety); past either it reports and ends. Never keep working to look busy.

## f. Report

After a pursuit, one short block as a comment on the drive issue and in the session, nothing else written
anywhere; the issues and pull requests are the record.

```text
Done from the proposal approved by OWNER:
Merged: #41, #42, #45 as one batch
Dispatched: #12 (haiku), #14 (sonnet)
Blocked: #13 on the owner (price of the plan), #9 on the payment provider
Filed: #51 (the exporter needs a date format, outside #12)
Skipped: #46, already merged by hand
```

## What a round never does

It never acts on a goal nobody approved, except asking. It never edits the owner's settings, CLAUDE.md or
AGENTS.md, the plugin, or the project's hooks. It never force-pushes, never deletes, never merges anything that
is not green, and never changes a State the owner set to waiting on owner except back to ready when the owner
has answered on the issue.

## Scheduling

Two ways to run it. A timed wake costs tokens even when nothing changed; the first step is cheap on purpose so
an idle wake is short, but it is not free. Match the interval to how fast the state can change.

**Inside an open session, with /loop.** Minutes while agents and merges are in flight; an hour when everything
waits on a person. In a session the approval is the question tool, so the person is present.

```text
/loop 10m /project-drive
```

```text
/loop 1h /project-drive
```

**A scheduled session, for overnight runs.** In the desktop app, a scheduled task whose prompt is
`/project-drive`, started in the project folder. Or a cron entry that starts a non-interactive session there:

```bash
cd /path/to/project && claude -p "/project-drive"
```

As a cron line, every hour on the half hour: `30 * * * * cd /path/to/project && claude -p "/project-drive"`.
Overnight the approval is a reply on the drive issue, so an unanswered proposal simply waits; the morning's
first round finds the reply and pursues it.

## Config

`.claude/project-drive.json` in the project, all keys optional:

- `runners`: how many agents may work at once (default 2)
- `maxAgents`: the most one round dispatches (default 4)
- `maxMinutes`: the most one round runs (default 90)
- `queueLogGlob`: where the merge queue writes its logs
- `ownerDecisions`: short phrases naming what is always the owner's, for example `["prices", "policy",
  "holders to ask"]`; a ready issue whose title or body contains one is asked about, never dispatched

The drive issue is created once by hand or by the bootstrap skill: one open issue labeled `drive`, titled
"Drive". `scripts/labels.sh` creates the label. The plugin's templates have a commented config example at
`templates/.claude/project-drive.json`.
