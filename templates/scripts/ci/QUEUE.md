# The merge queue

Merging should never take longer than the development did. One project merged seven app pull requests one at a time, each with its own full browser run, in ninety minutes. The same night, thirteen went into one integration branch with scoped tests per pull request and one full run, in twenty. The batch is the unit of merging; serial is the exception you name.

## When to batch

Any time two or more green pull requests are waiting. Run the queue with `--batch` and the numbers in the order you want them merged, oldest or most foundational first:

```bash
sh scripts/ci/merge-queue.sh --batch 41 42 45 47
```

What happens, in order: an integration branch named for the day is cut from main; each pull request is merged with a merge commit, so the originals show as merged and close their issues; after each merge the type-check runs and then only the unit and component test files that pull request touched, one file at a time; a pull request that conflicts or goes red is dropped with one printed line and the branch goes back to the last good merge; the status page is rebuilt; one pull request is opened whose body carries a Closes line per pull request; the one full run happens; the batch merges with a merge commit; the dropped ones go through the serial queue afterward.

## Drain: the queue that keeps going

Most of the time, nobody should pick the numbers. `--drain` reads every open pull request in one call, merges the green ones (as a batch whenever two or more are green, since merging one moves main under the other and sends it back through CI), waits while others are still running CI, and goes round again until nothing is left, nothing new turned green, six rounds have passed, or ninety minutes have:

```bash
sh scripts/ci/merge-queue.sh --drain
```

That is the command for "merge what is ready", so no agent writes its own loop. A pull request a round could not merge is not tried again in that drain; its line says why. A red pull request gets one retry of its failed jobs. When the drain ends, every pull request that conflicts with main or failed twice is listed under "Needs attention" and the drain exits non-zero, so an agent running it on a timer is woken by the failure instead of reading past a log line.

The drain holds a serial merge while other pull requests are still running CI. One green pull request merged alone moves main under every one of them, they are updated and sent back round CI, and the batch that should have followed has nothing. So with one or two green and others pending, the drain waits two minutes at a time until they finish, then batches; the hold is bounded by `QUEUE_DRAIN_MINUTES`.

## Unsticking, at a drain's end

A pull request that fell behind main, clashed with it, or went red for a reason that was not its code once sat until a person noticed. So every drain, the scheduled one included, ends by taking one stuck open pull request, in number order, and doing one thing for it; one, never two, so CI never runs two re-merges at once, and nothing that starts CI while another pull request's CI is still running:

- **Behind main, or shown as a clash but merging cleanly** (git merges main into it without a conflict): it calls GitHub's update-branch, the same call a serial merge makes, and CI runs on the new commit by itself. A red pull request is updated only when its red came from outside its code.
- **A real conflict:** one comment on the pull request naming the conflicting files and asking its agent to merge main in, and the `state:blocked` label. The comment carries a hidden mark with the head commit, so no drain, on this machine or a runner, comments twice on the same head.
- **Red only from outside its code, or cancelled:** it re-runs the failed jobs of the newest run on the head, once per head commit, and says why in a comment that carries the same kind of mark. Outside the code means every job that failed stopped on an install step that hit a Windows file lock (EPERM, EBUSY), a runner lost or shut down mid-run, a network error, a set-up step, or was cancelled with none of its own steps failed. An out-of-date lockfile is the change's own, EPERM or not, and a failed test beside any of these makes it the code's.
- **No checks at all on its head:** a run there is re-run once. With no run at all and nothing to merge in, the drain says so and does nothing: CI's pull-request jobs start only on a push to the pull request (its manual trigger runs main's gate instead), and the queue never pushes an empty commit.

A red pull request whose failure is in its code is its agent's turn, and is left alone. Held pull requests, an open batch's members, and everything while a rush change lands are left alone too. The rules are pure functions in `queue/rules-drain.sh` (`unstick_candidates`, `unstick_busy`, `outside_cause`, `unstick_action`), tested with fixtures; `QUEUE_UNSTICK=off` turns the step off.

## A re-run needs a reason

A drain's retry of a red pull request used to happen once per drain, so each new drain re-ran a rule check that had failed on an unchanged commit, and attempts 3 and 4 failed the same way. Now the drain re-runs the failed jobs of a red pull request only when something the checks read has changed since the failed attempt, or the failure looks like infrastructure (`queue/rerun.sh`, rules in `queue/rules-rerun.sh`):

- **Infrastructure** (a runner lost, a timeout, an install file lock, a network error; `outside_cause`) is always re-run, unless a rule check failed on the same run: a rule check fails again until something it reads moves.
- **The same commit and the same title and body** as the last time the drain looked: not re-run. The record is a hidden mark in a comment on the pull request (`merge-queue:rerun HEAD MARK`, the mark a fingerprint of the title and body), so a drain on a runner, which starts with nothing remembered, reads it too. The drain says in that comment what it did and why.
- **A new commit's first failure:** a failed test is re-run once (it may have flaked); a "Fail when ..." rule check is re-run only when the pull request was edited after the failed run ended. The spec, delete, mock, design and private-names checks read the live title and body, so editing the body counts as a change.
- **The same commit with an edited body:** re-run.

A red pull request the drain does not re-run stays on its report as failed, and is its agent's turn: push, or edit the pull request. A cancelled head keeps its once-per-drain re-run.

The checks job keeps each check's own output in `$RUNNER_TEMP/check.log` (`scripts/ci/check-log.sh`), and `failure-report.sh job` reads it into the annotation and the job summary. A run cancelled after a failed check therefore says which check failed and why, even though "CI passed" never starts.

## Held steps, recorded not remembered

An agent that means to act after another pull request lands records the wait on its own pull request, instead of keeping it in mind:

    sh scripts/ci/wait-for.sh PR AFTER [merge-main|"the step in words"] [SESSION]

It posts one comment with a hidden `merge-queue:after` mark and adds the `queue:after` label. Before unsticking, each drain's end reads the marks on the labelled pull requests. When AFTER has landed:

- **merge-main** (the default): the queue merges main into the pull request through update-branch, as unsticking does, and comments that it did. That is the drain's end's one re-merge, so nothing is unstuck after it, and it waits a drain while another pull request's CI is running.
- **any other step:** the drain's report says `Wake: #PR waited for #AFTER, which has landed; session NAME takes the step now: ...`, the session brief repeats that line, and a comment on the pull request says the step is due.

Either way the comment ends with a mark that closes the wait, and the label goes when nothing waits on the pull request any more. The waits still open go into the published state (`waits`), so the dashboard shows "Waiting for an agent" with what each waits for. The rules are `after_mark`, `after_marks`, `after_action` and `after_wake_line` in `queue/rules-drain.sh`; `QUEUE_HELD_STEPS=off` turns the step off.

## The queue on a timer

A drain started with `/loop` runs only while that session is open; close the app and six green pull requests sit until morning. Two ways to keep it going without a session:

- **A workflow.** `.github/workflows/queue-drain.yml` runs `--drain` every two hours on the project's own runners, as a backstop to the drains agents run after their own work. It never runs hosted by default: in a private repository whose hosted minutes are used up a hosted job is not started, and every scheduled run failed and emailed the owner. With the repository variable `QUEUE_RUNS_ON` unset it runs on a self-hosted Windows runner; set it to a runner's label to choose another (the template sync sets it from `ci.yml`). It holds that runner while it waits for checks, which is one reason a project keeps three. Each run drains for at most `QUEUE_DRAIN_MINUTES` (default 25) and skips itself when a drain finished in the last `QUEUE_DRAIN_GAP` minutes (default 10). It needs a classic token with `repo` as the secret `QUEUE_TOKEN`, because a merge made with the default token does not start the full run on main. Adjust the runner labels and the schedule.
- **An OS task.** On Windows, a scheduled task that runs `sh scripts/ci/merge-queue.sh --drain` from the repository every thirty minutes under the user who is signed in to gh; on macOS or Linux, the same line in cron. The queue's lock keeps a late run from overlapping an early one.

With a session open as well, `/loop 20m sh scripts/ci/merge-queue.sh --drain` still works; the lock refuses the second of two that overlap.

## The queue runs from a copy of itself

At start the queue copies `scripts/ci` and the worktree scripts to a temporary folder and runs from there. A shell reads a script as it goes, so an agent switching the main checkout to another branch during a drain could otherwise change the queue's code mid-run.

## Reading a drain while it runs

`sh scripts/ci/merge-queue.sh --status` prints one line: `running: a --drain started 12 minute(s) ago is still running (pid 4242); last line: ...` or `idle; last line: ...`. Every run's last line in the log is `queue done (exit N); lock released`, written after the deploy and after the lock goes, so a script that waits on the log waits on that line; the lock is logged when taken, too.

Every line the drain prints is also appended, with the time, to `.scratch/queue/log`, including the lines of the batch or serial runs it starts. A drain in the background can be followed with `tail -f .scratch/queue/log`. When the drain ends with "Needs attention", each pull request that failed CI twice comes with its failing check runs by name and the first error lines of each job's log, so the cause is in the output and not three more calls away. A listing that fails is reported as a failed listing and retried, never as an empty queue.

## Where the batch is built

The batch is built in its own worktree, a sibling of the repository named `<repo>-wt-batch` or the folder `QUEUE_WORKTREE` names, never in the main checkout, so a person working there is not switched onto the batch branch mid-drain. The worktree is reused; each package's `node_modules` is linked from the main checkout (the first worktree git lists, whichever folder the queue was started from) when the worktree has none, and when the main checkout has none to link either, the queue runs `npm ci` in that package first. A type-check that cannot run for want of packages is reported as that, not as a red base. Before anything is merged, the type-check runs once on the base there. A red base (packages not installed, generated types stale) stops the batch with "main is red here" and the first error, and drops nobody; that once dropped eight green pull requests for a fault none of them had. A test runner that cannot start stops the batch the same way.

## Inside the API budget

GitHub allows 5,000 API calls an hour for the account, shared by every tool and every agent. One evening with ten pull requests open, several waits running at once and `gh run watch` polling every few seconds spent it by midnight; from then every wait failed with a 403 that the queue reported as "not green yet", and nothing could land for an hour. The queue now paces itself:

There are two limits, and the one that bites is not the obvious one. The hourly quota (5,000 REST calls, 5,000 GraphQL points) was spent once by a fast watch loop. The secondary limit, on concurrent and point-heavy GraphQL requests, tripped on a night with seven agents and seven open pull requests while the hourly quota still showed thousands left: `gh pr list`, `gh pr view`, `gh pr checks` and the board script all go through GraphQL, and GitHub extends the block when callers retry at once. So:

- The queue makes every call through REST (`gh api`), which has its own budget and no points: one record per pull request per round, cached, plus one check-runs read. Nothing in the queue uses `gh pr` or `gh issue`.
- A refused call backs off, 90 seconds the first time and five minutes the second, and the third stops the queue. A spent hourly quota waits for the reset. The queue never retries at once.
- Every wait polls every thirty seconds, never faster, and the drain's rounds wait two minutes.
- Before each round and each wait it reads the budget (that call is free) and, when fewer than `QUEUE_RATE_FLOOR` calls are left (default 500), sleeps until the window resets and says so in one line.
- A 403 for the rate limit is named: "GitHub API rate limit reached; it resets at HH:MM UTC", and the queue stops.
- One queue at a time. A drain or a batch takes `.scratch/queue/lock`; a second one is refused with a line naming the first. A lock whose process is gone is taken over. A local queue also asks GitHub, once, whether the Queue drain workflow has a run in progress or queued, and is refused with a line naming it ("the Queue drain on GitHub started 12 minute(s) ago is still running (run 123)"); the workflow already skips while a local drain holds `QUEUE_LOCAL_DRAIN_UNTIL`, so the two never overlap. If that call fails (no network, rate limit) the queue says it could not check and goes on.
- The session brief shows the remaining budget when it is low.

Never write a watch loop around the queue, and never run `gh run watch` with its default interval; run `--drain` and let it pace itself. If you must watch one run by hand, `gh run watch ID -i 30`. For agents working alongside the queue: one queue process at a time, no drain on a timer faster than the drain's own rounds, 90 seconds between retries after any rate-limit error, and `gh api` (REST) for one-off reads where a `gh pr` or `gh issue` command would do the same through GraphQL. The board scripts must use GraphQL, since Projects v2 has no REST API; keep them to the coordinator, not every agent.

The drain workflow's `QUEUE_TOKEN` decides whose budget the queue's polling spends. A token of the owner shares the owner's 5,000 with every agent on the machine. A token from a separate machine account gives the queue its own 5,000, and the workflows' default `GITHUB_TOKEN` has its own per-repository budget as well, so the scheduled workflows never compete with the agents.

Which token does what. The drain workflow passes two. `GH_TOKEN` is the workflow's own token (`github.token`, with `checks: read` and `statuses: read` in the workflow's permissions); every read the queue makes uses it, check runs included. `QUEUE_MERGE_TOKEN` is the secret `QUEUE_TOKEN`; the queue uses it, through `gh_write`, only for calls that change GitHub (merge, update-branch, labels, comments, workflow dispatches, closing a pull request), so those still start follow-on workflows. The checkout also uses `QUEUE_TOKEN`, so a push from a batch starts CI. A fine-grained `QUEUE_TOKEN` needs Contents, Pull requests, Issues and Actions read and write, Commit statuses read, and Workflows read and write (a batch branch can carry a change to `.github/workflows`, and GitHub refuses such a push without it). It cannot have Checks, because fine-grained tokens have no such permission; that is why reads do not use it. A classic token with `repo` and `workflow` covers all of it.

## Who the queue signs in as

Best first. **The queue's own GitHub App**: `npx sipnship queue-identity` makes it in two clicks and sets the secrets `QUEUE_APP_ID` and `QUEUE_APP_KEY`; the drain, the audit and Deploy mint its installation token at each run with `scripts/ci/queue-app-token.sh` (openssl and curl, no outside action ever holds the key). Without the App, the secret `QUEUE_TOKEN` (and `RUNNER_WATCH_TOKEN` and `ADMIN_TOKEN` where they read runners). With none of them, the workflow's own token.

The drain reaches SipNShip with the run's own identity token (`id-token: write`, audience `https://sipnship.dev`, asked for at each use by `scripts/ci/service-auth.sh`); a machine uses the token `npx sipnship connect --repo` kept. When the queue cannot sign in at all it writes the "Merge queue" issue instead.

## With no queue App

A push, a pull request or a merge made with the workflow's own token starts no other workflow; GitHub documents two exceptions, `workflow_dispatch` and `repository_dispatch`. Proof, by that documented behaviour and not by a live run: a dispatched run of `ci.yml` reports its check runs on the commit of the ref it ran on, and a pull request's required check is matched by name on its head commit whichever event started the run (the gate always runs a `workflow_dispatch` run, `scripts/ci/gate-lib.sh`). So with `QUEUE_OWN_TOKEN=yes` the queue starts CI itself: on the batch's branch once its pull request is open, and on the base after a landing (`ci_dispatch` in `scripts/ci/queue/state.sh`). A change that touches workflows cannot be landed by the workflow's own token; the queue says so and the change waits for a drain run on a machine. If a project pins its required check to a particular app, keep `QUEUE_TOKEN` or the queue App.

## Opening and reading pull requests without GraphQL

`sh scripts/pr-open.sh "TITLE" BODY_FILE [BASE] [HEAD]` opens a pull request through REST, with the body read from a file, and prints its address; `sh scripts/pr-checks.sh N` prints the check runs on a pull request's head, one per line, and the one-word rollup the queue reads. Both spend the REST budget and nothing else. `gh pr create` and `gh pr checks` go through GraphQL.

## Only through the queue

A direct `gh pr merge` is refused by the plugin's merge hook in any project that has this script, with one line pointing here. The queue is what checks the folder, waits for a quiet main, batches, cleans up the worktree and records flaky tests; a merge that skips it skips all of that.

## A change that needs a migration run

A pull request that adds a migration merges only after the migration has run. The queue reads the manual on the pull request's own branch, and refuses while the migration's line still says "Not yet run" or no line mentions it. Run it, change the line to "Done" with the date on that branch, and queue it again. Migrations are the `migration` kind in `.claude/numbering.txt`; the manual is `SETUP.md` or the `manual` line in `setup-paths.txt`.

## What never costs another pull request a re-run

The serial queue merges a green pull request without a second CI run when main moved only outside its classes, and updates it for a re-run when main moved inside them. Some classes can never make CI red: `docs`, `specs` and `status`, named on the `!rerun-free` line of `classes.txt`. The queue ignores them on main's side. Without that, ten pull requests that each named a spec invalidated one another on every merge and went round CI one at a time, which is what this file exists to prevent. If your project has another class whose moves are harmless, add it to that line.

A green pull request that merges cleanly onto main also merges without a second run when main moved in its classes, as long as main's newest run, on main's current commit, is green. The full run on main is the gate, as the rules say, and it opens the red-main issue if the two together fail. The re-run is kept only when main is red or its newest commit has not finished its run. One batch went through three full CI cycles for the same code under the old rule. `QUEUE_RERUN=classes` restores it: re-run whenever main moved in the pull request's classes.

## Release channels follow Deploy

What the releases are and when the queue starts them are two settings. `"releases"` in `.claude/deploy.json` lists them; `"releaseOn"` says when: `"deploy"` (the default) starts each once after a landing that deploys, where no Deploy run starts them; `"ask"` never starts them after a landing, and `sh scripts/ci/merge-queue.sh --release` starts each once, on request. A release workflow that is turned off in Actions is never started: the queue prints `release held: <file> (it is turned off)`, because a project that holds releases until its owner says go turns them off on purpose. With `"ask"`, a release on `workflow_run` of Deploy still follows Deploy; take that trigger off and keep `workflow_dispatch`.

A release build (a Play internal upload, a Firebase App Distribution, a TestFlight build) starts after Deploy, never after CI. A workflow on `workflow_run` of CI builds and uploads on every merge to main: a serial landing round once uploaded 29 Play versions in an afternoon, each a full build on a self-hosted runner. Deploy runs at most once per landing round, started by the queue when the gate says a deploy is due (or by its own schedule), so a release that follows it runs once per round:

```yaml
on:
  workflow_run:
    workflows: [Deploy]
    types: [completed]
    branches: [main]
  workflow_dispatch:

jobs:
  release:
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
```

The release's first step is the gate, the same one the queue uses, so a deploy started by hand cannot stack builds in front of CI:

```yaml
    steps:
      - uses: actions/checkout@v4
      - id: gate
        run: sh scripts/ci/deploy-gate.sh || echo "skip=yes" >> "$GITHUB_OUTPUT"
      - if: steps.gate.outputs.skip != 'yes'
        run: # the build and the upload
```

The gate prints one line and skips when another open pull request is green (it lands first; one deploy carries both) or the interval in `.claude/deploy.json` has not passed since the last successful Deploy run. The queue applies the same rule after every landing, in every mode, and a drain once at its end; there is no `--deploy` flag, because a flag an agent must choose not to pass is passed again. `--status` and the session brief print the deploy state as one line. The owner forces a deploy from the Deploy workflow's own dispatch in the Actions tab, never through the queue.

The Deploy workflow itself has no gate step, on purpose. Its scheduled run has its own throttle (the same interval, counted from when the deployed commit landed), and its manual dispatch is the owner's override, which a gate must never refuse. The gate belongs to what Deploy starts (the release workflows) and to the queue.

After the gate, the queue asks whether anything that ships changed since the last deployed commit (`refs/deploy/production`), by the same rule the Deploy workflow uses (`ships_path` in `deploy-lib.sh`, with `appRoot` and `neverShips`). When nothing did, it prints `deploy: skipped, nothing that ships changed` and starts nothing, neither Deploy nor the releases that follow it; the next landing that ships deploys everything since. A template sync that touched only `scripts/ci/`, workflows and `.claude/` once started a web build and two Android builds. The plugin's own scripts (`scripts/ci/`, `scripts/design/`, `scripts/*.sh`) never ship; a project's other non-shipping folders go in `neverShips`.

`"intervalMinutes": 0` in `.claude/deploy.json` deploys after every landing unless another pull request is green, which is what `--deploy` did before 0.16.0. The sync offers it to a project whose files still pass `--deploy`.

The repository variable `DEPLOY_INTERVAL_MINUTES`, when it is set to a whole number, comes before `intervalMinutes`: a hosted dashboard may keep it as a setting (0 after each landing, 60 at most every hour), so the interval changes with no pull request. The gate, the deploy health line and the Deploy workflow all read it the same way (`deploy_interval` in `deploy-lib.sh`): a workflow passes `vars.DEPLOY_INTERVAL_MINUTES` in the environment (empty when there is none), and a session reads it once over REST. With no variable, the file decides, as before.

The release checks its own paths (did `android/` change since the last upload?) and skips when nothing it ships moved. List the release workflows in `.claude/deploy.json` under `"releases": ["play-internal.yml", "app-distribution.yml"]`: when the project has no Deploy run to follow (the guard path), the queue starts each of them once instead, after a landing, when the gate says a deploy is due. Sync names any workflow still on `workflow_run` of CI.

A release that runs on a pushed tag is tagged by the queue. After every landing, before any deploy gate, each merge commit that moved the version in `QUEUE_RELEASE_TAG_FILE` (default `plugin/package.json`) gets the tag `QUEUE_RELEASE_TAG_PREFIX` plus that version (default `plugin-v`), pushed over REST with the queue's write token, so the workflow on that tag starts; a tag pushed with a workflow's own token would start nothing. It happens only where a workflow names such a tag (`plugin-v*`). The log says `release: tagged plugin-v1.4.0 on abc1234`; a tag that already exists is said and left alone, and a refused push names the command to push it by hand.

## The batch checkout's packages

Each package in the batch checkout has the packages its lockfile names: linked to the main checkout's `node_modules` when nothing differs, installed there (`QUEUE_INSTALL_COMMAND`, default `npm ci`) when the lockfile or a `file:` dependency's tree differs from what the installed packages came from. A `file:` package (`"@app/core": "file:packages/core"`) is installed by copy, so a repack that lands on main without touching the lockfile counted as no change once, and the batch refused to start with "main is red" on a type error main did not have. The tree of every `file:` path is part of the hash now, and when an install fails the refusal says the checkout's packages are older than main rather than blaming main. A workspace is one unit: when the checkout root has a `pnpm-workspace.yaml`, or a `package.json` with a `workspaces` field, the hash is the root lockfile (`pnpm-lock.yaml`, `package-lock.json` or `yarn.lock`) plus each member's `package.json`, the install runs once from the root with the matching tool (`pnpm install --frozen-lockfile`, through corepack or npx when pnpm is not on the path; `npm ci`; `yarn install --immutable`), and when the hash is the main checkout's the root and each member's `node_modules` are linked. `QUEUE_INSTALL_COMMAND` overrides the tool. Projects of separate packages keep the per-package behaviour above.

## Checked-in build output

A project that checks a built package into the repository (a shared Kotlin core's JS package, a generated client) has every pull request that touches its source commit a rebuild too, and two such pull requests conflict on the generated files even when their sources do not. Six green ones once landed one at a time for it, each with a merge from main, a rebuild and a full CI run: an hour of landings for twenty minutes of work. List those files in `scripts/ci/generated-paths.txt`, one glob per line, with the command that rebuilds them on a `rebuild:` line. When a pull request conflicts with the batch only in those files, the queue takes either side, runs the rebuild on the batch branch, and lets the batch's one full run prove it; nothing is dropped. Without a `rebuild:` line it takes either side and says the full run must prove the files.

The rebuild runs in the batch checkout with the queue's own environment: whatever the shell that runs the queue has, and nothing more. A Gradle rebuild that needs a JDK names one with a default, so the line works on a machine that has `JAVA_HOME` and on one that does not: `rebuild: JAVA_HOME="${JAVA_HOME:-/opt/jdk-21}" ./gradlew :core:jsPackage`. A drain on a hosted Linux runner cannot run a Windows-only rebuild; set the repository variable `QUEUE_RUNS_ON` to the runner that can, and the drain workflow and the sync both warn while it is hosted. A pull request dropped for a conflict whose files are all generated says so in its line and its comment ("generated only: a rebuild on the batch would resolve this"), so a serial round is known to be avoidable.

## Holding a pull request, pausing the schedule

- **Hold one pull request.** A label `queue:hold` (or `hold`), or a line `Queue: hold` in its body, keeps a green pull request out of every drain and batch. `--serial N` refuses it too, unless a person gives a reason with `--because`. Remove the label or the line to release it.
- **Pause the scheduled drain.** `sh scripts/ci/merge-queue.sh --pause 2h` (or `45m`) sets the repository variable `QUEUE_PAUSED_UNTIL`, and the scheduled drain skips itself until then; `--resume` ends the pause. A drain you run yourself still runs.
- **A session's own drain** sets `QUEUE_LOCAL_DRAIN_UNTIL` to now plus `QUEUE_DRAIN_MINUTES` (default 25) when it starts, renews it each round, and clears it when it ends, however it ends. The scheduled drain skips while that time is ahead and the published state (the "Merge queue" issue) does not say idle; so a drain that died holds the backstop off for one window at most. A batch folder git no longer knows is moved aside as `<folder>.stale-<date>` and made afresh, and a drain that ends with green pull requests it could not batch says why in its last line, which the published state carries ("The queue stopped at 3:29 AM: the batch folder could not be made").
- **A re-run** is of the newest CI run on the pull request's current head only, only when none of its runs is queued or running, and a cancelled head once; a second cancel on that head is named "cancelled twice; look at it". Re-running an older run would cancel the fresh one through CI's concurrency group.
- **Land this next reserves the machines.** While a land-next request is open, the queue, at every tick and first thing at the tick that reads it, cancels the running and queued checks of every other pull request (never a batch's run, a rush test head's or a run on main), notes each as paused in the published state ("Paused for a rush change", muted, the agent's badge, never red), and leaves the machines to the rush one; a machine counts as free only when GitHub lists no job on it, since a cancelled run's step runs to its end on a Windows runner ("finishing a cancelled run"), and a free one reads "Reserved for #N" while the rush one's jobs are queued. A second land-next queues behind the first in the order asked, as a chain: it is tested on a draft test head of main plus those ahead of it (`rush-<N>-on-<ahead>`, built as the batch builds its members, never merged itself), so when those land it merges on that result with no further run, and when one ahead goes red the ones behind are tested again without it. When the rush list is empty, every paused check is re-run once, oldest first, by the re-run rule above, and the queue goes on.
- **A rule change says why it went first.** The rules-sync pull request's request carries the reason "First because it changes a rule" (origin "rule change" in core); the queue's say line for it repeats the reason, and the dashboard's Work card and Queue chip hover say the same words.

Setting a repository variable needs a token that can administer the repository; the owner's own `gh` sign-in can.

## Land now, and waking a drain

A green pull request's card has Land now beside Land this next: the same serial merge for that one change, with the same rules (`--serial`, never red, never beside a drain). Land this next also reserves the machines and waits for its checks; Land now is for a change already green and cancels nothing.

Two queue runs cannot go at once, so neither runs beside a drain. A running drain honours the request at its next tick, which comes round every two minutes through a hold for others' CI; that hold is for ordinary green changes, and a land request is served before it. While a batch is being built there are no ticks, so a land request hears `after-drain` ("Next, after the drain that's running"), or `next-after-batch` if it is in that batch, each a step and not an end.

With no drain running, the request starts one. The service leaves the request's form on the Merge queue issue through its App; `.github/workflows/queue-wake.yml` wakes on that comment and dispatches the Queue drain. A drain already running keeps the new one pending, so it starts the moment the first ends and never beside it.

A drain in a workflow signs in to the service with GitHub's identity token (`service-auth.sh`), and reads and answers requests with it, as a connected machine does with its own.

## When to go serial

By choice, for a change that must land alone: a migration, a change to the deploy, anything whose failure you want to see on its own. Say so:

```bash
sh scripts/ci/merge-queue.sh --serial 48
```

Two or fewer pull requests with no flag also run serially. More than two with no flag are refused, by the script and by the `require-batch-merge` hook, until you name the mode.

## Runners

Every open pull request starts its own CI run on every update. Once a pull request is in a batch, its own run is competing with the batch's run for the same runners and proving nothing the batch does not. The queue cancels a carried pull request's in-progress run for that reason. If you batch by hand, cancel them yourself.

The batch goes first on the runners without the queue pausing anyone. Where `ci.yml` keeps one runner for the batch and main, pull requests' own jobs never take that one, so a batch's run and main's always have a machine; the queue keeps the runners' labels right at the start of every drain, with no step for a person (`RUNNERS.md`, "One runner kept for the batch and main"). And a run's jobs join the line together rather than one after another, with a run whose checks fail cancelling itself (`RUNNERS.md`, "A run's jobs join the line together"), so the jobs ahead of a batch are fewer and none of them is a doomed run's.

## What the queue says while it waits

The queue reads the run it waits on and says plainly what is happening, so a stuck run is a line of output and not half an hour of diagnosis.

- **"GitHub Actions is down, not your code."** When a job's annotation says it was not acquired by a hosted runner, or a job has sat queued for more than five minutes while runners of ours were idle. The line adds GitHub's own status for Actions when it is not operational. If the project has an outage switch, set `QUEUE_OUTAGE_ON` and `QUEUE_OUTAGE_OFF` to the commands that flip it, for example `gh variable set CI_OUTAGE --body 1` and `gh variable delete CI_OUTAGE`; the queue flips it on for that run and off again when the run goes green.
- **"CI failed: lint, test."** The failing jobs by name, and the failing tests read from the run's log.
- **"The run you are waiting on was canceled; re-running it."** Instead of silence.
- **"Holding the merge: a run on main is in flight."** The queue never merges while a run on main is in progress, so a proof run on main is never canceled by a merge. It holds for up to twenty minutes, then says so and merges.

The wait is bounded by `QUEUE_WAIT_MINUTES`, default sixty; past it the queue says so and stops, and a later run picks up.

## An unreliable test is a bug, not weather

The queue keeps a record under `.scratch/queue/flaky.tsv`: each test that failed on a pull request and then passed on a retry, by name, with the pull request and the day. A test that flakes twice gets an issue filed, labeled bug and ready, naming the pull requests it cost, and the queue says so. After that it is not re-run again; it is fixed or quarantined under its own issue. A pass counts as a flake only on the same head commit and the same pull request body as the failure, with a test step among the failed ones: a rule check (a "Fail when ..." step, such as a missing Mock: line or a deletion without a Deletes: line) that passes once the body is edited is a fix, recorded `cleared`, and so is a pass after a new push. The record is local to the machine that runs the queue, which is the one that sees every result.

## Before a self-hosted runner's first run

Run the doctor on the machine: `sh scripts/ci/runner-doctor.sh`. It checks the four things that cost a real project four tries: which bash a step would get (Windows puts WSL's first), whether Git, Node and gh are on the machine PATH the runner service sees, PowerShell's execution policy, and whether the runner is online. Then run the `Runner check` workflow from the Actions tab once; it is the job-level shell default and the PowerShell step, written the way that works.

## What the queue needs from the project

- A type-check command. It uses `npx tsc --noEmit` when any `tsconfig.json` is checked in, run once in each package a change touches (the nearest folder above each changed file with a `tsconfig.json`), so an app in `web/` is checked from `web/`. Set `QUEUE_TYPECHECK_COMMAND` for the project's own command, which runs once from the root. With neither, the type-check step is skipped.
- A one-file test command. By default it runs `scripts/ci/run-test-file.mjs`, which drives the test runner's own API for one file so the hook that refuses sweeps is not in the way. It runs the file from its own package, the nearest folder above it with a `package.json`, where its `node_modules` and runner config live. Set `QUEUE_TEST_COMMAND` to another command that takes one file. A runner that cannot start is not a red test: the batch stops and prints the runner's error instead of dropping every pull request.
- Branch protection on main that requires only the `CI passed` check and leaves "require branches to be up to date" off.
