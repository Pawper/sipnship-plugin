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

One invocation is one tick: do the next step, then end. No wait loops. A tick either proposes or pursues an
approved proposal, decided in step a.

## Rounds of units

The drive works the ready list in rounds, so many issues land in little time without overwhelming the queue.

- **A unit** is one agent, one worktree, one pull request. It is a bundle of issues that touch the same files,
  or a loose issue that shares files with nothing else. The plan script makes the bundles (step c,
  `dispatch`).
- **Units in a round share no area**, so their pull requests batch together and land in one pass. An area is
  a name from the list the project keeps in `.claude/areas.txt`: one area a line, its name and then the paths
  it covers (its spec folder and source folders; a folder ends in `/`). A unit names its areas from that list,
  by name or by a path inside one, so two units in the same files are seen as such whatever words they use.
  `publish-round.sh` refuses two units that share an area, with what to do: bundle them, or hold one behind
  the other. When two issues in one area must still run side by side, an `apart:` line says why, and the
  Work tab shows it.
- **Feedback during a round joins the plan, not a new agent.** When a person brings up a change while a round
  runs, the coordinator files it as a ready issue (`scripts/issue-open.sh`, State ready) and leaves the
  planning to the drive. An issue in an area a running unit owns goes to that unit: the same agent, in the
  same pull request or the one after it, published again with the issue on that unit's line. Otherwise it
  waits in Ready for the next round, where the plan looks at it beside the others and bundles it. Three
  exceptions start work at once: the person says to start it now; something is broken and blocks work; or it
  is a fix to an open pull request that is red or conflicts with main. A round published by hand is held to
  the same rule: `publish-round.sh` refuses a unit in an area the running round owns.
- **Bundles rank before loose issues**: a round fills with the units that carry the most issues first, up to
  `unitsPerRound`. Splitting one big issue into parts is not a bundle.
- **A project's plugin or CI work goes in one bundle.** Issues touching `plugin/`, `scripts/ci/` or
  `.github/` share one test suite, so they always clash; the plan puts every such issue into one bundle and
  holds plugin work while a plugin unit is running.
- **One round at a time.** The next round is proposed while the current one runs, planned against the files
  it is changing, and started only when the current one has landed (its units merged or set aside).
  `approval.sh` holds an approved `dispatch` while the latest started round still has issues In progress, and
  says so on a `held:` line; landing, fixing and asking go ahead meanwhile.
- **Every open pull request keeps moving**, not only the round's own. The plan reads each open pull request
  over REST and its `mergeable_state`: one that conflicts with main and is not held by the queue is a
  `merge-main` goal, and a red one no unit owns is a `fix-pr` or `set-aside` goal like any other. Nobody has
  to ask for this. Never put two agents on the same pull request: one a running unit owns goes to that unit's
  agent, not a new one. And never send an agent to a pull request someone else is already working on: one
  whose head commit or newest comment is under 30 minutes old is likely in an agent's hands in another
  session, so the plan shows it on an unnumbered `busy` line instead of `merge-main` or `fix-pr`, and a later
  tick looks again.

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

**Auto Drive.** The drive issue may carry the label `drive:auto`, which the builder sets with the Auto Drive
switch on the dashboard or by hand on GitHub. Both scripts read it with the one REST call that finds the drive
issue; the plan's last line says which it is. With the label on, approval is standing: `approval.sh` approves
the latest proposal whole, ending "approved by Auto Drive", so the round starts the next round as soon as the
current one has landed (its last pull request merged), with no reply. "Start this round" on the dashboard
still starts it at once: SipNShip's app leaves it on the drive issue as `Queue request: start-round by LOGIN`,
and `approval.sh` approves the proposal whole for that person, even while a round runs. A round published
with `publish-round.sh` counts as the proposal when no numbered one covers it, one `dispatch` goal per unit,
and once that round is published as started, the request is spent. With the label off,
dispatch only on a reply or that request: post the proposal and wait, as below.

**Requests from the Work tab.** SipNShip's app also leaves `Queue request: start-next #N by LOGIN` and
`Queue request: hold-agent #N by LOGIN` on the drive issue. They are a person's word about one issue, so they
need no proposal or reply. Read them on every tick, whatever `approval.sh` said:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/work-requests.sh"
```

It prints one line per request still owed, `start-next N by LOGIN` or `hold-agent N by LOGIN`, or nothing. Do
each (step c), and answer on the drive issue in the fixed form, one comment each, so the dashboard's waiting line
ends. A request nobody answers tells the person it did not happen: a start after a day, a hold after an hour.

**Answers to what was asked.** A choice pressed on a Needs you card is written on the issue (or on its pull
request, when the question was asked there) as two lines, the second in a fixed form: `Builder answer: #N
choice K by LOGIN`, ending `changes <comment id>` when it replaces an earlier answer. A person may write the
same line by hand on GitHub, and it counts. Read them on every tick too:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/answers.sh"
```

It prints one line per answer not yet read, `answer #N choice K by LOGIN (comment ID)`, or nothing; `--all`
lists every answer still owed, read before or not. The answer is the builder's decision: carry on from it on
that issue, in the next round's proposal or at once when the round already holds it, and say on the issue
what you are doing with it. A comment from anyone else after the answer means it was acted on, and the line
stops. The issue has already moved to Ready, so a round that missed the line still proposes it with the
answer above it.

The plan's closing lines also say the round's settings (`rounds:`, with the units per round, the dispatch
model and the red limit), `summary: due` when the daily summary should be written (below), and `health:`
when a health note is set (below).

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
- **`landing N N: ...`** (unnumbered). In a project whose queue drains by itself, green pull requests are
  left to it; nothing to do.
- **`drain N N`.** Green pull requests have sat 15 minutes without landing: run `sh
  scripts/ci/merge-queue.sh --drain` once, in the background, and end the tick. One drain, never a loop.
- **`fix-pr N`.** Read the failing check. If the cause is inside the pull request's own scope or is a
  test-environment problem (a flaky test, a cancelled run, a missing fixture), fix it on that branch (or have
  the unit's own agent fix it in its worktree), re-run the touched tests locally, and push; CI runs again.
  Otherwise leave one comment on the pull request naming the cause and set its issue to `state:blocked`.
- **`set-aside N TITLE (red K times)`.** The pull request has been red `setAsideAfterReds` times (on
  different commits). Stop fixing it: one comment on its issue naming the cause in plain words, set the issue
  to `state:blocked`, and the unit leaves the round, so the round can land without it.
- **`merge-main N TITLE`.** The pull request conflicts with main and the queue does not hold it. Dispatch one
  agent (isolation, `dispatchModel`) to its branch's worktree: merge origin/main, keep both sides, regenerate
  any generated files, re-run the touched tests per file, and push. Never a second agent on a pull request
  that already has one; a unit's own pull request goes to that unit's agent.
- **`busy N TITLE`** (unnumbered). The pull request would get `merge-main` or `fix-pr`, but its head commit or
  newest comment is under 30 minutes old: someone is likely on it. Send nobody; a later tick looks again.
- **`dispatch N`.** Start an agent for the issue with isolation (a worktree), the model `dispatchModel`
  names (or, when it is empty, the model the plugin's agent-model hook allows for its tier), and a brief that
  names the issue, the files it may touch, the rules in CLAUDE.md or AGENTS.md (install right after the
  worktree is made, run every touched test per file, keep test files inside `.scratch/`, merge origin/main
  before pushing, never run the queue or re-run CI), and the pull request it must open with `Closes #N`.
  Dispatch every unit of the round at once. Set the issue to `state:in-progress` with `scripts/state.sh`.
  The plan groups ready issues by the files they are guessed to touch (the paths and specs the body names,
  the project's mocks map, and the files past work on the same spec changed). `dispatch 12 14` with a
  third column "Why together: both change ..." is a bundle: one agent, one worktree, one pull request that
  closes every issue named, with a `Closes #N` line for each. Units in one proposal never share an area, so
  they run side by side. When the agent starts, note how it started so the machine can report it: append
  `WORKTREE-NAME<TAB>round` (or `next` for a one-off start, `hand` for a terminal) to
  `.scratch/drive/started-with.tsv`. One round runs at a time: propose the next while this one runs, planned
  against the files the running bundles change.
  The dashboard's Work tab draws a round from a comment on the open issue labeled `drive`, so publish the
  round whenever you propose it and again when you dispatch it (also when a coordinator is acting as the
  drive): write the round to `.scratch/drive/round.txt` (one `unit:` line per agent with its issues, `why:`,
  `areas:` from the project's list and, once its pull request opens, `pr:`; `hold:` lines for work waiting,
  with `after:` and `areas:`; an `apart:` line with `why:` for two issues in one area kept apart, which the
  Work tab shows beside the round; one `waits:` line in plain
words when the whole proposed round waits for something, such as a usage window or a blocked issue, so the
tab says it waits and on what instead of saying it starts on its own; `status: proposed` or
  `status: started`; the format is at the top of the script) and run
  `sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/publish-round.sh" .scratch/drive/round.txt`. With `status: started`
  it also sets each unit's issues to In progress, so dispatching a unit is what moves its issues; publish
  again with `pr:` filled in when an agent opens its pull request. Name the issues in the agent's brief
  or its branch (`issue-538`) so the machine's session report finds the unit.
  The next round is always on the Work tab: while a round runs, publish the proposed next round (`status:
  proposed`) beside the started one, and publish it again only when it changes. The service keeps the
  started round and the proposed one apart, so both show.
- **`start-next N by LOGIN`.** Start this issue now if a runner is free and nothing running touches its files:
  dispatch it as a one-off, set `state:in-progress` (from Parked or another set-aside State too, since the person
  asked for it by name), note `next` in `started-with.tsv`, and answer `Queue answer: start-next #N: started-next`.
  Otherwise make it the first unit of the next round you publish, and leave it unanswered: the dashboard says
  "First in the next round" until it starts. If the issue closed, answer `Queue answer: start-next #N: not-open`.
  If it cannot start at all, say why in one comment on the issue and answer `... : not-started`.
- **`hold-agent N by LOGIN`.** Tell the agent working the issue, if this session started it (your runtime's
  message to a running agent): finish the current step, commit and push what is done, and stop. Then set
  `state:waiting-on-owner` with `scripts/state.sh`, which moves the card to Needs you, and answer
  `Queue answer: hold-agent #N: held-agent`. An agent you cannot reach (another session's, or one in a person's
  terminal) is not held: change no State and answer `Queue answer: hold-agent #N: not-held`, so the person hears
  it at once. Never set the State without stopping the agent.
- **`hold N TITLE After: RUNNING TITLE`.** The issue touches files a running bundle touches. Do not start it;
  it is shown as waiting after that bundle and is planned again in the next proposal. It needs no approval
  and does nothing.
- **`ask-owner N`.** A ready issue whose words touch something the owner has said is theirs. Put one comment
  on it with the question, the options and a recommendation, and set `state:waiting-on-owner`. This is a
  proposal line so the person sees it, but it is the one goal that may run without approval, since it asks
  rather than acts. Ask once, then wait: the issue leaves the ready list and is never asked again until the
  owner answers (`set-ready`). The same goes for an issue that turns out, on reading it in full, to need a
  decision: a design not yet approved, a spec not yet written. Write the comment as an ask (below), so the
  dashboard's Needs you card can say it.
- **`fix-main N`.** Treat the red run like a red pull request on main itself: fix within scope or report the
  cause on the issue.
- **`audit TEXT`.** When the facts are plain (an issue with no State whose title says what it is, an issue
  still ready after its pull request merged), set the state or close it. When they are not plain, leave it;
  the audit will say it again tomorrow.
- **`set-ready N`.** The digest says the owner has answered an issue still labeled waiting on owner. Confirm it
  by having one reader re-read that issue, then set it to ready with `scripts/state.sh`.
- **`mark-waiting N`.** The digest says a question to the owner is open on an issue labeled ready or in
  progress. Confirm the same way, then set `state:waiting-on-owner`.
- **`release X.Y.Z`.** Merged plugin changes sit unshipped. File a release issue first
  (`sh scripts/issue-open.sh`, State ready). In a worktree run `sh plugin/scripts/release/bump.sh X.Y.Z`, run
  the plugin suite (`sh tests/run.sh` from `plugin/`), commit, open the pull request with `Closes #N` for that
  release issue, and queue it. Publishing the split to the public repository happens by the release procedure
  after the merge (the publish workflow, once the publish token exists).
- **`restart-queue`.** Stop the queue process if one is still running, look in the main checkout for a stray
  modified tracked file and move it aside, then run the queue again.

## d. Hangups while pursuing

Three kinds, three moves, never a fourth.

1. **A fixable blocker**: a flaky test, a merge conflict, a cancelled run, a stuck queue. Fix it within the
   issue's own scope and go on.
2. **A decision only a person can make**: a price, a policy, a holder to ask, anything in the config's owner
   decisions list, anything the owner has said is theirs. One comment on the issue with the question, the
   options and a recommendation, written as an ask (below); set `state:waiting-on-owner`; move on. Never guess
   on a decision the owner has stated.
3. **Work outside the goal's own words**: file a new issue with a State label and leave it. Never widen the
   round. Widening is a new proposal, next round.

**How to write an ask.** Whoever sets `state:waiting-on-owner`, the drive or a coordinator, leaves one comment
the dashboard reads onto the issue's Needs you card. Context first, as much as the owner needs; then, at the
end, the ask in this shape:

```
Keep a year of watering history, or ninety days?
1. A year: older entries move to the archive each night. Recommended.
2. Ninety days: older entries are dropped, and the spec changes to match.
```

- The question is one line ending in a question mark, right before the choices. Name the decision in it:
  "Keep a year of watering history, or ninety days?", not "Which would you like?". The card shows that line
  alone, cut at 160 characters.
- The choices are a numbered list starting at 1, right after the question, no more than four. Start each with
  a short name, then a colon, then the detail: the card shows the name, cut at 80 characters.
- Every ask with choices recommends exactly one, however many there are: end the one you would pick with
  "Recommended." and a short reason why ("Recommended, since the spec you approved says a year."). The card
  marks it in words and always shows it, even past the fourth choice; an ask with none recommended says "No
  choice was recommended." on the card. Setting `state:waiting-on-owner` is refused while the ask left in
  the last ten minutes gives choices and none, or more than one, is recommended, or is a question with no
  choices (the `require-state-label` hook; the nightly audit names any that got through another way). Fix the
  comment, then set the state.
- A question that starts out open is turned into choices too, your best guess first, so the card always has
  buttons and a suggested one. Write the draft you would send as the first choice, and let the last be the
  builder's own words:

  ```
  What should the welcome email for new gardeners say?
  1. Use this draft: "Welcome to Maya's rooftop garden. Your first bed is ready to plant." Recommended, it says the garden's name in its first line.
  2. I will write my own on the issue.
  ```
- Comment and set the State together: a comment more than ten minutes older than the State is not read as its
  reason, and a later ask on the issue replaces an earlier one.
- No quoted lines or code in the ask itself; they are never read. The card shows the words as written, in
  quotation marks, so write them to the owner, plainly.

## e. Stop

A round ends when its proposal is posted, when the approved goals are done or blocked, when the ready list is
empty, or when everything left waits on a person. Say which in one line. A round also stops when it has
dispatched its agent budget (`maxAgents`, default four) or run for its minute budget (`maxMinutes`, default
ninety); past either it reports and ends. Never keep working to look busy.

When the proposal carries a `wake:` line, a pull request's checks are still running and nothing will bring
the round back when they finish. In an interactive session, schedule exactly one wake-up for that many
seconds (your loop skill's self-paced wake, or your cron tool with `recurring: false`), never a poll; when it
fires, run a new round. On a scheduled session the next tick already covers it, so do nothing. In the desktop
app its own pull request watch reports a red check; the wake is for the green case.

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

## The daily summary (optional)

With `summaryAt` set (a local time such as `"07:00"`), the plan prints `summary: due` once that time has
passed and today's summary is not on the drive issue yet. Write it once, as one comment on the drive issue
starting "Summary for YYYY-MM-DD" (the local day), then carry on with the tick: each round with its units,
what landed and when, what deployed, what was set aside and why, what waits on the owner, and the last health
note if one is set. Plain words. Without `summaryAt`, no summary.

## The health note (optional)

With `healthNote` set, the plan runs its command (which prints one number) and prints a `health:` line. Over
`above`, it recommends a restart: say so in the report and the daily summary. It only recommends; it never
pauses or holds work, and a figure it cannot read changes nothing. Without it, no note.

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

In the desktop app, ask the agent in plain words ("start the drive loop every ten minutes"); the input box
refuses a command typed inside another, so the agent starts the loop itself. In a terminal session, type the
loop command below. A scheduled session, next, takes `/project-drive` as its prompt, unchanged.

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
- `unitsPerRound`: the most units one round holds, within `maxAgents` (default 2)
- `dispatchModel`: the model each unit's agent runs on, for example `"sonnet"` (default empty: the model the
  agent-model hook allows for the issue's tier)
- `setAsideAfterReds`: how many reds, on different commits, before a pull request is set aside instead of
  fixed again (default 2; 0 never sets aside)
- `summaryAt`: the local time of the once-a-day summary, `"HH:MM"` (default empty: no summary)
- `healthNote`: `{"command": "...", "name": "...", "above": N}`, a command that prints one number about the
  machine, what it is in plain words, and the figure over which a restart is recommended (default empty
  command: no note). It never pauses work.

The drive issue is created once by hand or by the bootstrap skill: one open issue labeled `drive`, titled
"Drive". `scripts/labels.sh` creates the label. The plugin's templates have a commented config example at
`templates/.claude/project-drive.json`.
