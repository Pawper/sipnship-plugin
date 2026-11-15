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
- **A hold takes no slot twice.** An issue the drive published as a `hold:` in its last round, while its
  reason is still true (what it waits on is still open, its pull request still open), is left out of the next
  plan's slots, so they go to the next ready unit, after the project's `priorities`. The `defer` line says how
  many held issues kept out of the round, so a small round is explained. A held issue's reason is read again
  each run; when it ends, the issue is planned like any other.
- **A project's plugin or CI work goes in one bundle.** Issues touching `plugin/`, `scripts/ci/` or
  `.github/` share one test suite, so they always clash; the plan puts every such issue into one bundle and
  holds plugin work while a plugin unit is running.
- **One round at a time.** The next round is proposed while the current one runs, planned against the files
  it is changing, and started only when the current one has landed (its units merged or set aside).
  `approval.sh` holds an approved `dispatch` while the latest started round still has issues In progress, and
  says so on a `held:` line; landing, fixing and asking go ahead meanwhile.
- **In progress is not taken on faith.** An issue is In progress only while an agent is on it. Before it judges
  whether the round has landed, the plan checks each In progress issue: with no open pull request and nothing
  touched in two hours (no comment, no commit on a branch named for it or for any issue of its unit), or with
  its pull request held for the person, it is not a running unit. The issues of one started unit are touched
  together and go back together, and an open pull request that names an issue in a `Part of` line, or is its
  unit's own `pr`, counts as its pull request. The plan prints a `stale:` line naming it and sets it right over REST: back
  to Ready, or to Waiting on you when its pull request is held, with the hold's ask on it (one question,
  numbered choices, exactly one recommended). The queue does the same at a merge: an issue a merged pull request
  left In progress returns to Ready. Never leave an issue In progress with nobody on it.
  A round has landed when every unit's pull request has merged or closed, whatever its issues show: an issue
  of such a unit that the pull request did not name (found already done, or left in part, with a closing note)
  does not hold the next round, and the plan sets it back to Ready on that tick with a `stale:` line, not two
  hours later. `approval.sh` holds a dispatch only while a unit has an open pull request (held ones too) or has
  none yet and an issue In progress. A drive without this reading does it by hand on the tick: for each started
  unit whose pull request is no longer open, put every issue of it still In progress back to Ready (one comment
  saying the pull request landed without it), then plan.
  An issue that an open pull request already closes (a `Closes #N` line, in a member of the running batch or in
  a held one) is never proposed as `dispatch`: the plan prints a `hold` line naming the pull request instead.
- **Every open pull request keeps moving**, except one held for the builder to read (`queue:hold`, or a
  `Queue: hold` line). Send no fixer and no merge-main to a held one, red or conflicting: its rule checks show
  on its card for the builder, and it runs no test parts until they let it land (`full_run_decide`). The plan
  reads each open pull request
  over REST and its `mergeable_state`: one that conflicts with main and is not held by the queue is a
  `merge-main` goal, and a red one no unit owns is a `fix-pr` or `set-aside` goal like any other. Nobody has
  to ask for this. Never put two agents on the same pull request: one a running unit owns goes to that unit's
  agent, not a new one. And never send an agent to a pull request someone else is already working on: one
  whose last push (the head commit's time, never the pull request's update time) is under 10 minutes old when red, or under 30 when it conflicts, has an agent at work (a comment, your own post, a worktree or a check re-run never counts: none ends when the agent does),
  so the plan shows it on an unnumbered `busy` line instead of `merge-main` or `fix-pr`, and a later
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
`Queue request: start-now #N by LOGIN` and `Queue request: hold-agent #N by LOGIN` on the drive issue. They are a person's word about one issue, so they
need no proposal or reply. Read them on every tick, whatever `approval.sh` said:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/work-requests.sh"
```

It prints one line per request still owed, `start-next N by LOGIN`, `start-now N by LOGIN` (N is 0 for the round-wide button; one that carries the builder's own words prints as `start-now ? by LOGIN: WORDS`, one line each, so read the words and match each to its issue; `Queue answer: start-now #0: ...` spends them all), `hold-agent N by LOGIN`
or `start-round by LOGIN`, or nothing. Do each (step c). Every request is answered on the drive issue in the fixed
form `Queue answer: KIND #N: outcome` (start-round's N is 0), one comment each, saying what happened or what it
waits on, so the dashboard's waiting line ends; a request still printed on the next tick is one you owe, so answer
it then. A request nobody answers tells the person it did not happen: a start after a day, a hold after an hour.

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
answer above it. A held pull request: an answer whose choice lets it land already lifted its `queue:hold` in
the service when it was written, so no session changes the label, and you never do. A plan line starting
`held:` names a pull request still held although its question was answered: that answer did not let it land,
so it stays held until the builder lets it land; say so on the issue, and do not try to release it.

The plan's closing lines also say the round's settings (`rounds:`, with the units per round, the dispatch
model and the red limit), `summary: due` when the daily summary should be written (below), and `health:`
when a health note is set (below). A `plugin:` line says the copy running the drive is older than the latest
release; carry it into the report on the drive issue, since faults already fixed come back in the plan until
the installed copy is updated.

## b. Propose, or pursue

**When nothing is approved and the proposal has goals:** put the proposal to a person and stop.

- In an interactive session, use the question tool: list the numbered goals as options, let the person pick
  several, and treat the picks as the approval. Go to step c in the same round.
- In a scheduled or non-interactive session, post the numbered proposal as one comment on the open issue
  labeled `drive`, starting with the word "Proposal" and ending with one line: "Reply with the numbers to
  approve, all, none, or all but some." Then end the round. The person answers on the issue; the next round
  reads it.

Every comment the drive writes from a file goes through `sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/comment.sh" ISSUE
FILE`, never a hand-written `gh` call: `gh api -f body=@file` posts the file's name, so the script posts with `-F`
and refuses a missing or empty file and a body that is only a path. The readers of the drive issue skip a
comment whose whole text is a bare `@path`, so one slip is never read as an answer.

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
  left to it; nothing to do. When the `queue` fact reads `batch N`, an open pull request carries the queue's
  batch marker and its members are already landing: no drain is proposed while it is open.
- **`drain N N`.** Green pull requests have sat 15 minutes without landing (their age is read from each head
  commit's own check runs; one whose age cannot be read counts as old enough, and the line says so): run `sh
  scripts/ci/merge-queue.sh --drain` once, in the background, and end the tick. One drain, never a loop.
- **`fix-pr N`.** Read the failing check. If the cause is inside the pull request's own scope or is a
  test-environment problem (a flaky test, a cancelled run, a missing fixture), fix it on that branch (or have
  the unit's own agent fix it in its worktree), re-run the touched tests locally, and push; CI runs again.
  Otherwise leave one comment on the pull request naming the cause and set its issue to `state:blocked`.
- **`set-aside N TITLE (red K times)`.** The pull request has been red `setAsideAfterReds` times (on
  different commits; a red whose failing check was also failing on main at the time is not counted, and
  such a pull request is proposed as `merge-main` once main is right). Stop fixing it: one comment on its issue naming the cause in plain words, set the issue
  to `state:blocked`, and the unit leaves the round, so the round can land without it.
- **`merge-main N TITLE`.** The pull request conflicts with main and the queue does not hold it. Dispatch one
  agent (isolation, `dispatchModel`) to its branch's worktree: merge origin/main, keep both sides, regenerate
  any generated files, re-run the touched tests per file, and push. Never a second agent on a pull request
  that already has one; a unit's own pull request goes to that unit's agent.
- **`busy N TITLE`** (unnumbered). The pull request would get `merge-main` or `fix-pr`, but its head commit
  is recent (under 10 minutes when red, 30 when conflicting): an agent is at work. The wait runs from the last push alone; a comment, label or check finishing never restarts it, and once it passes, a fix agent goes at the next tick. Send nobody; a later tick looks again. A red pull request with nobody on it is never a reason to hold the round: dispatch the units in other areas anyway, and say in the proposal's waits-on line what waits and since when once it passes an hour.
- **`busy N TITLE` and `hold N TITLE` for the rest.** Every open pull request gets one line: one whose checks are
  still running or whose merge state is not known yet is `busy`, one held for the builder's read is `hold`.
  Nothing is sent to either.
- **`held N N: green, waiting for the builder's read`.** A green pull request held for the builder (the
  `queue:hold` label or a `Queue: hold` line) is never landed by the queue, so it is off the `landing` line and out
  of the count that proposes a `drain`; this one unnumbered line keeps it in the proposal. Nothing is sent to it.
- **Tidy ended worktrees without being asked.** When the brief names a backlog of worktrees (more than ten besides
  the main checkout), run `sh scripts/worktrees.sh prune --apply --closed` once in the round's tidying step. It removes only
  clean worktrees whose pull request ended, keeps every commit in its branch (a closed one under a `closed/NAME` tag), and names each one it skipped and why;
  it never deletes a folder with uncommitted files, and the drive does not remove anything by hand.
- **Check the worktrees folder before any agent starts.** A tick woken on a self-hosted runner runs as the runner's
  service account, which may not reach the folder worktrees live in, and every agent it started would fail at its
  first step. `approval.sh` runs `sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/worktree-access.sh"` and drops `dispatch`,
  `merge-main`, `fix`, `start-next` and `start-now` goals with one `held:` line when it prints `held:`, `waits:` and
  `detail:` lines instead of `ok`; run it yourself before starting an agent by any other road. On a `held:`, start no
  agent, set no issue In progress, and put the `waits:` line in the published round (the Work tab shows it, in plain
  words) and the `detail:` line in a secondary line of the proposal comment; landing, proposing and tidying go on.
  The folder is `worktreesDir` in the config when set, else where the project's worktrees already live. Never
  work around it by making a worktree somewhere else.
- **`dispatch N`.** (A `First: why` field on the line says the project's priorities put it first; keep it in
  the posted proposal: "First: it unblocks your reviews".) Start an agent for the issue with isolation (a worktree), the model `dispatchModel`
  names (or, when it is empty, the model the plugin's agent-model hook allows for its tier), and a brief that
  names the issue, the files it may touch, the rules in CLAUDE.md or AGENTS.md (install right after the
  worktree is made, run every touched test per file, keep test files inside `.scratch/`, merge origin/main
  before pushing, never run the queue or re-run CI), the pull request it must open with `Closes #N`, and, when
  it must ask the owner, to write the ask for a builder who is not technical as "How to write an ask" below
  says (what happened, the question about their project, short-named choices, the reason as their benefit).
  Dispatch every unit of the round at once. Set the issue to `state:in-progress` with `scripts/state.sh`.
  Keep the brief in a file and the prompt short: name the issue, the worktree and the pull request to open, and
  point at the brief file ("read your brief first and follow it"). The agent-model hook reads such a prompt as a
  unit of work, never a lookup, so `dispatchModel` is allowed for it whatever its length.
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
  proposed`) beside the started one. The service keeps the started round and the proposed one apart, so
  both show.
  The round file also carries how the plan sized it and what it left out: one `sized:` line with the plan's
  own `sized:` words ("5 runners online, 4 free for agents"), which the Work band's "Why this many" tip says,
  and a `hold:` line for each unit the plan deferred, with `why: No free runner this round`
  (`deferred_holds` in `scripts/drive/round-lib.sh` prints them from the plan's `defer` line; `sized_line`
  prints the `sized:` line; add each unit's `areas:` to its hold line, which the script requires), so a small round is explained and a deferred unit says why it waits.
  Every run publishes the proposed round, even one that starts nothing: a `hold:` line for each issue you
  hold back, with `why:` its reason in the builder's words ("Waits on your read of the bed map design",
  never "nothing buildable") and `after:` or `pr:` naming what it waits on, read afresh this run; a round of
  holds only is a round. When your judgement declines what the plan proposed, that issue is a hold whose
  `why:` says so, so the builder can overrule it with Start this next. An unchanged round is updated in
  place with the time of this look, so the tab shows when you last looked apart from when the round changed.
- **A rush: `start-next N by LOGIN` or `start-now N by LOGIN` (N above 0).** Replan and bundle a rush on the tick it is read,
  never on the next round. Put N in one unit with every ready or proposed issue it shares an area with, and bundle
  several rushed issues with each other first (`RUSH_ISSUES="N M" sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/plan.sh"`
  puts that unit first). Dispatch the unit this tick when no running unit or open pull request touches its area;
  otherwise it leads the next round. Publish the proposal again so the dashboard shows the bundle.
- **`start-now N by LOGIN`, N above 0.** The press was on that one issue: start that issue, at once, as its own
  unit when it shares no area with a running unit or an open pull request (bundled only with what it shares an
  area with), even when the proposal posted a moment ago did not include it. Never answer it with a new
  proposal. Answer `Queue answer: start-now #N: started-now`, or, when it waits, say what for (the running
  unit and area it shares) in that same answer.
- **`start-now 0 by LOGIN`.** Dispatch every unit of the proposed round that shares no area with a pull request
  still landing, this tick; the rest wait for what they share. Answer it as below, or say what it waits on.
  The dashboard's round-wide button leaves `Queue request: start-now by LOGIN` with no
  issue, which prints as `start-now 0 by LOGIN`: it names no rush, so it means exactly this, for every unit,
  and its answer is `Queue answer: start-now #0: started-now` (or what it waits on).
- **`start-round by LOGIN`.** Answer it once the round started: `Queue answer: start-round #0: started-round`.
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
- **`hold N TITLE Waits on ... (after: M)`.** The issue says it comes after #M, which waits on the owner or is
  still open. Do not start it; publish it as `hold: N | after: M | why: <those words>`. A hold the plan no
  longer prints has ended: start it like any ready issue.
- **`ask-owner N`.** A ready issue whose words touch something the owner has said is theirs. The line says which
  phrase matched and the sentence it matched in (`matched "prices" in: ...`), because a phrase also matches as an
  ordinary verb. A match is a candidate, not a decision: read the issue with one reader first, and when it does
  not leave that decision open, add its number to `.scratch/drive/no-ask.txt` (one `N` or `N<TAB>why` a line) so
  the plan does not propose it again, and start it as an ordinary ready issue. Otherwise put one comment
  on it written for the builder as "How to write an ask" says (what happened, the question about their
  project, short-named choices, the recommendation's reason as their benefit), and set `state:waiting-on-owner`. This is a
  proposal line so the person sees it, but it is the one goal that may run without approval, since it asks
  rather than acts. Ask once, then wait: the issue leaves the ready list and is never asked again until the
  owner answers (`set-ready`). The same goes for an issue that turns out, on reading it in full, to need a
  decision: a design not yet approved, a spec not yet written. Write the comment as an ask (below), so the
  dashboard's Needs you card can say it.
- **`fix-main N`.** Treat the red run like a red pull request on main itself: fix within scope or report the
  cause on the issue.
  A ready issue whose title or body says a test or check fails on main is ranked first as well: the plan puts its
  dispatch ahead of every bundle, so it is never the one deferred for want of a runner. Whoever files such an issue
  can also label it `ci-red`. Its goal also opens the proposal and carries `First: A fix for a failure on main`, so
  `approval.sh` never holds it behind the running round (the round it blocks could not land without it), and
  the plan proposes no `drain` while one is ready: it prints a `landing` line saying the round waits on the fix.
  When the plan's last line says `auto drive: not known`, the lookup of the drive issue failed; it does not mean
  there is no drive issue or that Auto Drive is off, so run the plan again.
- **`note: N branch(es) are still on the remote ...`** (unnumbered, never a goal). Branches left on the remote after their pull request ended are the nightly audit's to report; nothing the drive may do ends one, so the plan shows the count as a note and proposes no action for it.
- **A round never waits on an unrelated ask.** With Auto Drive on, a proposed round starts as soon as its areas and runners are free. A change held for the owner's read, or a red change waiting on a fix agent, holds no runner and does not count as the running round (`approval.sh` leaves a `queue:hold` pull request out of the running ones); only its areas stay taken. A unit waits on another only when it truly depends on it (the same files or area, or it needs the answer to be built), and the band's "Waits on" names that dependency, never "the current round has not finished".
- **`audit TEXT`.** When the facts are plain (an issue with no State whose title says what it is, an issue
  still ready after its pull request merged), set the state or close it. When they are not plain, leave it;
  the audit will say it again tomorrow.
- **`set-ready N`.** The digest says the owner has answered an issue still labeled waiting on owner. Confirm it
  by having one reader re-read that issue, then set it to ready with `scripts/state.sh`.
- **`mark-waiting N`.** The digest says a question to the owner is open on an issue labeled ready or in
  progress. Confirm the same way; when the ask is more than ten minutes old, post it again (rewritten for the
  builder, below, when it is not already), then set `state:waiting-on-owner`: an older ask is not read as the
  wait's reason, and the hook refuses the State without a fresh one. When the reader finds no open question
  (a design note or a list "to settle in the spec" is not an ask), leave the State alone and run
  `sh "${CLAUDE_PLUGIN_ROOT}/scripts/board/digest.sh" no-question N`, which records it in the digest, so the same
  `mark-waiting` is not proposed on every tick until the issue changes. Like `ask-owner`, it runs without approval,
  since it only moves an issue to where the question already is, and only for an ask in the shape: the latest
  comment gives the question and numbered choices, exactly one ending "Recommended." (`scripts/ci/ask-lib.sh` is
  the one reader, and the state-label hook refuses the change otherwise). An open question that is not in that
  shape is not marked: ask the agent that wrote it to put it in the shape, and mark it then, so Ready holds only
  what can start. The plan checks this itself with the one reader before it proposes `mark-waiting`; an open
  question not in the shape comes out as `ask-fix N` instead, with what to change. A closing note an agent left
  of what it did not build (a comment with a `Left:` or `Not changed, because` line that asks nothing and offers
  no choices) is not a question: the plan reads the newest comment and prints no `mark-waiting` or `ask-fix` for
  it, so the issue stays as it is.
- **`ask-fix N`.** An open question to the owner that is not in the ask shape. Ask the agent that wrote it to put
  it in the shape when that agent is reachable (an interactive session). A scheduled tick has no such agent: the
  agent that wrote it ended long ago. Then the drive acts itself, after one reader confirms what the issue
  really waits on. A decision becomes an ask with choices, written from the issue's own words (below, "How to
  write an ask"); a step only the owner can do outside the app (a measurement that needs an administrator, a
  secret, a runner) becomes an `Instructions:` comment with numbered steps. Post it with `comment.sh`, then set
  `state:waiting-on-owner` with `scripts/state.sh`. When the reader cannot tell, or the drive cannot write it
  without guessing, leave the issue and run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/drive/ask-fix-seen.sh" N`: the
  plan then prints it as an unnumbered `hold` (not a goal) until the issue changes, so it is not proposed again
  every tick. When the one reader finds the comment is only a note of what was left, not a question, run
  the digest's `no-question` word for that issue (as for `mark-waiting`) and leave the issue as it is. An issue with an `ask-fix` or `mark-waiting` line is never in a `dispatch` line of the same
  proposal; it is a `hold` that says it waits on the owner.
- **`unasked N`.** The issue is set to waiting on the owner, but no ask or `Instructions:` comment is in force
  on it (none was left since the State was set or in the ten minutes before), so the builder's card has nothing
  to answer. It is the drive's to set right on this tick, never the builder's, and it runs without approval.
  Have one reader say what the issue waits on. When a decision or an owner's step is open, write it (as for
  `ask-fix`, below in "How to write an ask") and post it with `comment.sh`; the issue keeps its State. Otherwise
  set it back to Ready with `scripts/state.sh`, with a one-line comment saying nothing waits on the builder.
- **`release X.Y.Z`.** Merged plugin changes sit unshipped on the remote's main (the plan fetches it, so a stale checkout proposes the same release). When an open issue already names that release the plan prints an unnumbered `hold` naming it instead: never file a second release issue or open a second bump. File a release issue first
  (`sh scripts/issue-open.sh`, State ready). In a worktree run `sh plugin/scripts/release/bump.sh X.Y.Z`, run
  the plugin suite (`sh tests/run.sh` from `plugin/`), commit, open the pull request with `Closes #N` for that
  release issue, and queue it. Publishing the split to the public repository happens by the release procedure
  after the merge (the publish workflow, once the publish token exists).
- **`deploy (N landed changes are not live yet, the oldest for M minutes)`.** Changes that ship landed on the
  remote's main at least ten minutes ago, none is deploying, and production still holds an older commit. A landing
  starts its own deploy (the queue, and the Deploy workflow when a drain finishes), so this is the net under both:
  start the Deploy workflow once with `gh api -X POST repos/{owner}/{repo}/actions/workflows/deploy.yml/dispatches -f ref=main`
  (REST, so it spends no GraphQL points), then say in the report on the drive issue that it was started and
  at what time. Never start a second while one is running (the plan prints nothing then). When the agent is not
  allowed to start it, say so and give the owner that one command instead of retrying. Do not wait for it to
  finish; the next tick's plan shows whether production caught up.
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
the dashboard reads onto the issue's Needs you card. Its reader is the builder the mission names: someone who
is not yet technical, who knows their project and not our machinery. Write it for them, in this order:

1. **What happened**, in one or two plain sentences about their project: "A change that broke the watering
   schedule was added to your app, and nothing warned you." Not the agent's working words ("the skip
   detection", "both gaps").
2. **The question**, as a decision about their project, not about our tools: "Should every change to the
   watering schedule be tested before it is added?", not "Should the CI template close both gaps?".
3. **The choices**, two to four. Each starts with a short name of a few words, then a colon, then what it
   means for them: what they get, what it costs in time or money, what stays as it is.
4. **The recommendation**: end the one you would pick with "Recommended" and its reason as a benefit to them
   ("Recommended, so a broken schedule never reaches your beds"), never where something is written ("since
   the issue's Done when line asks for it").

A term such as CI, spec or pull request is allowed, never forbidden: make it easier where it stands ("a pull
request, the proposed change with what it does") and link it when it names something they can open. Never leave
it bare, and never put a script name, file name, label name or path in the question or a choice's name.

A bad ask, written in our words (the builder cannot tell what happened, what each choice changes for them or
what it costs; the reason points at a line in an issue; two choices have no short name, so the card cuts them):

```
Should the watering job close both gaps at once?
1. Yes, fix both: tighten the skip detection so the moisture job never skips when the sensor source changed, and make the nightly run open beds-red. Recommended, since the issue's own "Done when" line asks for exactly this.
2. Only add the automatic beds-red filing for a red nightly run; leave the skip detection as it is for now.
3. Leave the watering template alone for now; treat Saturday's case as a one-off and do nothing more.
```

The same ask, rewritten for the builder:

```
On Saturday a change that broke the watering schedule was added to the garden app, and nothing warned you: the test that would have caught it was skipped. It showed up an hour later, when the nightly run failed.

Should every change to the watering schedule be tested before it is added?
1. Test every change first: a broken change never gets in, and each change takes about five more minutes to land. Recommended, so a broken schedule never reaches your beds.
2. Warn me within minutes: changes land as fast as now, and you hear the moment one breaks something.
3. Keep it as it is: nothing changes, and a break like Saturday's can happen again.
```

Both are fixtures of the check (the plugin's `tests/fixtures/ask-plain/`). The shape, which the card reads:

- The question is one line ending in a question mark, right before the choices. Name the decision in it:
  "Keep a year of watering history, or ninety days?", not "Which would you like?". The card shows that line
  alone, cut at 160 characters.
- The choices are a numbered list starting at 1, right after the question, no more than four. Start each with
  a short name, then a colon, then what it means for them: the card shows the name whole only up to 80
  characters, and a choice with no colon is named by its first sentence, so a long one is cut mid-sentence.
- Every ask with choices recommends exactly one, however many there are: end the one you would pick with
  "Recommended." and its reason as a benefit ("Recommended, so the watering log covers a whole season."). The
  card marks it in words and always shows it, even past the fourth choice; an ask with none recommended says
  "No choice was recommended." on the card.
- Setting `state:waiting-on-owner` is refused when no ask or `Instructions:` comment was left in the last ten
  minutes (the builder would find nothing to answer), and while that ask gives choices and none, or more than
  one, is recommended, is a question with no choices, offers reading as a choice, has a choice whose short name
  the card would cut, gives a reason that points at an issue's section, a file or a number, or carries a script,
  file, label or path in its question or a choice's name (the `require-state-label` hook, in all three forms:
  `gh issue edit`, the REST labels call and `sh scripts/state.sh`; the nightly audit names any that got there
  another way, and the plan proposes them as `unasked N`). Each refusal says how to fix the ask. Fix the
  comment, then set the state. Whether the words read plainly beyond these is your judgement: read the ask
  once as the builder before you post it.
- Reading is never a choice. An ask about something to read (a spec, a mock, a held change) names it by its
  title, with a link that opens it, and its choices are the outcomes that follow the read: "Approve it",
  "Ask for changes" (the builder says what, and the agent takes it from there), and any real alternative
  ("Split it: the spec waits for your read, the rest lands now"). No choice reads: never "Read it first",
  "Read it and let it land", "Look at it later" or "Decide later": the builder is in the drawer to read it,
  and a choice that only puts the decision off decides nothing. The hook and the audit refuse such an ask,
  saying what to write instead. An open ask in an old shape is rewritten once, keeping its place in line.
- The scripts' own ask about a held change (the queue's and the plan's, `held_ask` in `scripts/ci/ask-lib.sh`)
  is written this way and goes on the issue the held pull request closes, once; never on an issue it only
  names or one that was In progress in the same round.
- A step asked of the builder is one that exists. Never write an Instructions step naming a permission the
  builder cannot grant, such as a "Checks" permission on a fine-grained token (GitHub offers none): the
  drive reads checks from the Actions runs and commit statuses, so its token needs Actions, Administration
  (read, to list runners), Commit statuses, Contents, Issues, Pull requests and Workflows.
- A question that starts out open is turned into choices too, your best guess first, so the card always has
  buttons and a suggested one. Write the draft you would send as the first choice, and let the last be the
  builder's own words:

  ```
  What should the welcome email for new gardeners say?
  1. Use this draft: "Welcome to Maya's rooftop garden. Your first bed is ready to plant." Recommended, it says the garden's name in its first line.
  2. I will write my own on the issue.
  ```
- Comment and set the State together: a comment more than ten minutes older than the State is not read as its
  reason, and a later ask on the issue replaces an earlier one. To put an issue in front of the builder for an
  ask left earlier, post it again (rewritten in this shape when it is not), then set the State.
- A step the owner does outside the app (add a secret, bring a runner online, run a command) is Instructions,
  never a decision. Start the comment's first line with the word `Instructions:` and a short title, then the
  steps as a numbered list (what to do, where, any value or command in code), with no choices and no
  "Recommended.". The card shows the steps with Done, and the hook accepts it as an ask without a
  recommendation:

  ```
  Instructions: Set up the sensor hub for the herb beds
  1. Add a repository secret named `FROST_SENDER_KEY` in the repository's settings, under Secrets.
  2. Install the hub on the rooftop network by running `npx sensor-hub install --bed herbs` in a terminal.
  ```

  Use choices only for a real decision. Two choices that are "do the step" and "set it aside" are an owner
  action dressed as a decision: the hook refuses them and the nightly audit names them. When you can see the
  steps are already done (the secret exists, the runner is online), say so on the issue and move it on
  instead of waiting.
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

- `runners`: an optional cap on how many agents work at once; with no key the plan reads the runners GitHub lists, online and not busy, less one kept for the queue, and names that number on its heading line
- `maxAgents`: the most one round dispatches (default 4)
- `maxMinutes`: the most one round runs (default 90)
- `worktreesDir`: the folder the project keeps its agents' worktrees in; with no key it is the folder the existing worktrees share, else a `worktrees` folder beside the project. The drive checks it can write there before it starts an agent, and the runner install grants the runner's account access to it
- `queueLogGlob`: where the merge queue writes its logs
- `ownerDecisions`: short phrases naming what is always the owner's, for example `["prices", "policy",
  "holders to ask"]`; a ready issue whose title or body contains one is asked about, never dispatched
- `priorities`: an ordered list of the kinds of work that go first, after fixes for a failure on main. Each entry
  is one string, `"NAME: why"`: NAME an area from the project's areas file or a label, and why the words a unit
  says for going first, for example `["review: it unblocks your reviews", "queue: it makes your rounds faster"]`.
  The plan fills free slots from these first (the earliest entry first), and prints `First: why` on the unit's
  `dispatch` line, so say it in the proposal. A unit that went first is not held behind a running round (the
  plan already holds one that shares an area with it); on approval its dispatch goes ahead beside the round.
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
