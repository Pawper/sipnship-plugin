---
name: project-bootstrap
description: Stand up a new project so many agents can work in it at once without colliding. Use at the start of a project, before the first feature agent runs, or when an existing project shows the symptoms (docs that grow by appending, merge conflicts on shared files, a merge queue that waits on full test runs, a project board nobody feeds).
---

# Project bootstrap

The lesson this comes from: rules written for one agent become pathologies when thirty follow them at once, and
the codebase is the one surface every agent must write to, so anything that lives there is something they all
collide on. Decide the homes and the enforcement first, then let agents build.

## Before anything: a short survey

Do not copy a file until these are answered. Look in the repository first (the remote URL, a `.gitlab-ci.yml`
or `.github/`, the package manifest, an existing `specs/` or `docs/` folder, a `CLAUDE.md`), state what you
found, and ask only what you could not tell. Ask in one message, as a short list, with your inference as the
default for each. In Claude Code use the question tool so the person can pick rather than type.

| Question | Why it matters | Changes |
|---|---|---|
| Is there a sibling repository to copy the stack from? | A studio's second project has the same tracker, CI, runners, test command, spec tool, database layout and console shape as its first; reading them from that repo answers eight of the rows below in one go | Every row marked (sibling): take the answer from the sibling's CLAUDE.md Stack heading, its `.github/workflows/ci.yml` `runs-on`, its `scripts/ci/classes.txt`, `setup-paths.txt`, `.claude/numbering.txt` and `console/services.json`, and confirm them in one line |
| New project, or an existing one showing the symptoms? | An existing project needs the hooks and checks first and the moves to new homes second, one at a time | The order of the outputs; what is moved aside rather than created |
| Where do issues live: GitHub, GitLab, Jira, Linear, other? (sibling) | Every home in section 1 points at the tracker | The issue template, the board script, the state script, the audit, the filing hook's label |
| Where does CI run: Actions, GitLab CI, Buildkite, other? (sibling) | Section 4 is a set of jobs; the file that holds them differs | Which workflow files are copied or translated |
| Which agent runtimes will work here: Claude Code only, or others too? (sibling) | Hooks are per runtime; a rule with no hook needs a CI check instead | Whether AGENTS.md is a copy or the primary; which rules get a weaker check |
| What is the one-file test command? (sibling) | The sweep hook needs to know what a targeted run looks like; CLAUDE.md states it | The `TEST_COMMAND` placeholder; the per-class jobs |
| Which pages are generated? | The generated-page hook refuses edits to them | `.claude/generated-pages.txt` |
| Does any build output get checked in, and what rebuilds it? (sibling) | Two pull requests that each commit their own rebuild conflict on the output even when their sources do not; the queue resolves that on the batch only when it knows the files and the command | The globs and the `rebuild:` line in `scripts/ci/generated-paths.txt` |
| Spec tool: by hand, GitHub's spec-kit, something else, none yet? (sibling) | Step 7 and the spec check assume a folder per feature; the tool that fills it is the person's choice | Whether to run a generator inside `specs/<feature>/` or copy the skeleton |
| Where do CI jobs run: hosted, or the studio's self-hosted runners? (sibling) | Every job in ci.yml carries the `RUNS_ON` placeholder; a personal account has no runner groups, so there is no hosted fallback and the runner watch is what speaks when the runners are offline | `RUNS_ON` in `.github/workflows/ci.yml`: `ubuntu-latest`, or `[self-hosted, windows]` as both studio projects use; the gh-only workflows stay hosted |
| Where does it deploy, and does a self-hosted runner exist? (sibling) | Build CPU is most of a Vercel bill, and a project with many agents pushes many branches and merges main often; with the host's defaults every push is a build | The deploy path, set with `sh scripts/deploy-setup.sh [runner\|vercel\|guard] [APP_ROOT] [INTERVAL]`: `runner` builds on our runner and deploys prebuilt on a schedule (best), `vercel` deploys on a schedule and lets Vercel build, `guard` keeps Git deploys but from main only, skipping changes that do not ship and throttled. Not on Vercel: say so once and apply the same idea, main only on a schedule or with a skip rule, if the host supports it |
| Where do existing mocks live, and what generates them? | Mocks left where they were made drift from the screens built from them, and nothing can check a picture it cannot find | They move into `design/mocks/` at step 1, generator beside them; with mocks there, step 7b makes one spec per area of the mocks and the mock check (section 4b) is an output |
| What is the owner's time zone? | Every dated line in the repository (decisions, the manual's migrations table, stubs, the notice, memory notes) is the owner's local day; gh output, runner logs and `date -u` are UTC, and an agent that dates from them writes tomorrow's date all evening | The `TIMEZONE` placeholder in the Stack section and in `.claude/session-brief.json`; the brief prints today in it |
| Where will the work folder live, and where is it backed up? | Step 6 is outside the repo and nothing can create it for you | The path named in CLAUDE.md |
| Is there a manual already, and where? (sibling) | The setup check asks for a line in the manual whenever a setup file changes; it must point at the one the project keeps | The `manual PATH` line in `scripts/ci/setup-paths.txt`; the manual row in the homes table |
| Which routine tasks and limits does this project really have? (sibling) | The console's FAQ must answer this project's questions, not the sample's | The `faq.required` ids in `console/services.json` |

Record the answers at the top of CLAUDE.md under a heading "Stack", three or four lines, so the next agent does not
ask again. The time zone goes there as "Dates are the owner's local day, America/Los_Angeles" (or whichever), and any
relative date an agent turns absolute, in a note or a memory file, is turned into that calendar's day, not UTC's. If the answers match the preferred stack, say so in one line and go on. If they do not, use section 0.

## 0. The stack this was designed for, and adapting to another

This skill and its plugin were built for GitHub (issues, a project board, Actions, the `gh` CLI), Claude Code
hooks, and a spec folder per feature in plain Markdown. Be honest about that: say it once when the project uses
something else, then adapt. Every home and every rule below is about a kind of place, not a product. When the
project does not use the preferred tool, propose the nearest equivalent and keep the rule:

| Preferred | If the project uses | Propose |
|---|---|---|
| GitHub issues, one per task | GitLab, Jira, Linear, a plain tracker | Their issue with a required State field or label; the PR or MR still closes it |
| GitHub project board with a State field | GitLab boards, Jira board, Linear views | A board grouped by State fed by the tracker's own automation, never a hand-kept page |
| GitHub Actions | GitLab CI, Buildkite, Jenkins, CircleCI | The same jobs: classify, per-class, one summary check, full run on main, red run opens an issue |
| `gh` in scripts | `glab`, a REST call, the tracker's CLI | The same scripts with the calls swapped; keep the pure parts, which are tool-free |
| Claude Code hooks | Another agent runtime | That runtime's pre-command hook if it has one; otherwise a CI check or a git hook, and say the rule is weaker |
| Spec folder per feature, written by hand or with GitHub's spec-kit | Any spec tool, or none | A folder per feature in the repo with a constitution and a spec file; the CI check holds either way |

What never changes: one home per kind of thing, nothing appended to a shared page, every rule has something that
enforces it, and the full suite gates main rather than the PR.

## 1. Homes: one place for each kind of thing

Write these into the project's CLAUDE.md (and AGENTS.md as a copy for other tools). Nothing goes anywhere else.

| Kind | Home | Never |
|---|---|---|
| Work, decisions, priorities | GitHub issues, one per task, filed before an agent starts; the PR closes it; decisions are comments on it | status files, TODO lists in the repo |
| Status at a glance | The project board, with a State field set at filing by the coordinator and moved to Done by GitHub's own automation when the PR merges or the issue closes | a hand-kept status page |
| Orientation for an agent starting cold | One short status page in the repo (a table with one row per feature and its state, a services summary, a not-done list), generated from one small stub per feature and checked in CI | per-day or per-item diaries |
| Data | The database, edited through the app's admin; seed files in the repo only as reviewable input to an importer, one file per unit so parallel changes touch different files | hand-written copies of data in prose |
| Research and findings | A work folder beside the source material, outside the repo, backed up off-site | the docs folder |
| Coordination state (what merged when, what was uploaded) | git history, CI, the storage bucket | written down by hand |
| The manual | One setup document: configuration, keys by name, migrations run | anything that changes per feature |
| Design | A spec folder per feature, with a constitution written once and a spec file per feature, written before building (by hand, or with GitHub's spec-kit if the project wants a generator) | design notes in issues only |
| Mocks | `design/mocks/`, with whatever generates them beside them; `scripts/ci/mocks.txt` maps each screen to its mock | mocks wherever they were made, a picture nobody built against |
| Credit for borrowed code or content | One short notice file, like any license notice | per-item narrative |
| Worktrees | One folder, named in CLAUDE.md, each removed when its pull request merges | scattered as siblings of the repository, kept after the merge |

## 2. Rules for every agent

- File the issue first, with a State. Work in an isolated worktree. Never force-push. Never delete; move aside.
- Nothing is appended to a shared page. A PR names its spec in its body (`Spec: specs/<feature>`) and changes the spec only when the design changed; it changes the manual only when a person must do a setup step; it changes a feature's status stub only when that feature's state changes; it adds no task to any file, because tasks are issues. A spec tool's tasks.md is written once at planning, each task becomes an issue, and the file is not touched again.
- Tests prove the change and run per file; the full suite is the gate on main, not on the PR.
- Everything a person sees is calm and plain, never a developer note (no issue numbers, fields, migrations).
- Report what was not done and why, not only what was. Say which commands were refused.
- No wait loops; bounded commands; stop every shell when done.
- At session start, reply from the session brief. Never run one network call per branch, worktree or issue in the foreground; the whole board is one call. Count long lists, do not print them.
- Titles and labels are not the state. For where each issue and pull request really stands, run `/project-status`: light readers summarize bodies and comments, only for items that changed since their last summary, and the orchestrator keeps one line per item.
- A clean folder is part of done: before reporting finished or opening a pull request, `git status` shows nothing outside the one scratch folder, `.scratch/`. Images and build output never go in a worktree. Stop every process you started from it.
- A fix to shared code gets its own issue and its own pull request.
- Work always has an ending: never move a branch from outside its worktree, never add a detached worktree, never close a pull request without a comment saying why or what replaced it.
- Merge only through the queue; a direct merge is refused. Its drain mode merges everything green, round after round, so nobody writes a loop.
- Never take a running number in a shared place: name tasks and setup steps by issue number, and reserve a migration number across main and every open pull request. A change that adds a migration merges after it has run.
- Use `git -C PATH` rather than `cd PATH &&` in a chained command.
- Worktrees live in one folder and go when their pull request merges. Removing the worktree of a merged branch is the one cleanup allowed, through the worktree script, because the branch keeps the work.
- Dispatch an agent with a model that fits its task: a light model for a lookup, a middle one for routine work, a heavy one only for hard work.

## 3. Enforcement: for every rule, what checks it

An instruction decays under load. For each rule, decide which of these makes it true, and set it up in the
first hour:

- **A hook that blocks the dangerous command** (delete, force-push, full test sweep, a direct write to a shared
  page, an issue without a State, an agent dispatched without a fitting model) rather than asking the agent to avoid it.
- **A hook at the end of a task** that refuses to finish in a worktree that is not clean: files outside the
  scratch folder, stray images or build output, a process still running from it. It refuses once and names
  what it found; the merge queue checks the same thing when a pull request is queued.
- **A CI check that fails on drift**: the generated status page, a source change without its spec, a setup
  change without its setup line, line endings, and, when the project has them, the data shape and the
  catalog-wide rules.
- **A required field at filing**, where the agent already has the information: an issue template with a State
  field, matching labels, and a hook that refuses an issue without one.
- **A scheduled audit that speaks only when something is wrong**: open issues with no State, issues left stale by
  a merged PR, a red main run; one comment on a tracking issue, nothing when clean.
- **A watcher on anything long-running** (a merge queue, an upload, a build), re-armed until it ends.
- **A brief at session start** that prints the live state, main, open PRs, the queue, what is in progress, the
  last handoff, what waits on the owner, so an agent starts from facts rather than from notes about the past.
  The plugin's SessionStart hook does this; a hook newly registered loads on the next session start, while an
  edit to a script already registered applies at once.

If a rule has none of these, either give it one or accept that it will not hold. Two rules in section 2 have no
mechanical check: "report what was not done" and "stop every shell." Say so in CLAUDE.md and review for them.

## 4. CI and merging from day one

- Classify a PR by the files it touches and run only what those touch; shard the slow suite across runners.
- One summary check, `CI passed`, waits for whichever class jobs ran and reports once. Branch protection on main
  requires exactly that check and never a per-class job, since those are skipped on purpose.
- The full run is the gate on main after every merge; a red main opens an issue automatically.
- The merge queue merges a green PR without a re-run when main changed only outside the PR's classes. This
  depends on "require branches to be up to date" staying off in branch protection.
- The batch is the unit of merging; serial is the exception you name. Two or more green PRs go into one
  integration branch, merged in order with merge commits, each proven by the type-check and only the test
  files it touched, then one full run and one merge. A PR that conflicts or goes red is dropped and goes
  serially afterward. Merging must never take longer than the development did; a hook refuses the serial
  pattern for more than two PRs unless `--serial` is named, which is right for a migration or anything that
  must land alone. A PR in a batch has its own CI run cancelled; it competes for runners and proves nothing
  the batch does not.
- No path filters that can skip a run on an update (a merge from main that touches only docs must still start one, or the queue waits forever).
- No hosted minutes by default. A project with its own runners runs everything on them: CI, the housekeeping workflows, Deploy and the scheduled drain (`QUEUE_RUNS_ON`, which the sync sets). The runner watch is a scheduled task on the runners' machine (`scripts/ci/runner-watch-install.ps1`, once, no admin), where it also reads the machine's load; there is no hosted runner watch, since in a private repository whose hosted minutes are used up it failed at every schedule. The nightly audit and the session brief say when a run sits queued. A hosted job bills at least a minute, the allowance is per account, and one project's housekeeping once spent it all and stopped every project's deploys.
- Three runners, each installed as a service: two so a pull request's jobs run side by side, one a drain may hold while it waits. `.claude/runners.json` says how many the project keeps; the doctor and the brief say when fewer are online; `scripts/ci/remove-runner.ps1` takes one away. The machine, not the count, is the limit: an idle runner costs about 90 MB and no processor, so the watch warns on jobs waiting while the processor idles (add one), on a saturated processor (fewer, or a second machine), on memory, on free disk below 15 GB where the runners work (the one that grows), and on more runners than half the cores across every project on the machine.
- The queue reads the run it waits on and says what is happening: GitHub's outage told apart from our
  failure, the failing check by name, a canceled run re-run, a merge held while a run on main is in flight.
- An unreliable test is a bug, not weather: the queue records a test that failed and then passed, and files an
  issue after its second flake instead of re-running it again.
- A self-hosted runner gets the doctor run on it and the runner check workflow run once before its first real
  run, so the wrong bash, a missing tool on the service's PATH and the execution policy are found first.
  `add-runner.ps1` needs an elevated PowerShell (the agent launches it with `Start-Process -Verb RunAs -Wait`
  and the owner clicks the prompt) and installs under `C:\actions-runner-<repo>`. On a Windows runner the
  `RUN_SHELL` placeholder in `ci.yml` and `queue-drain.yml` is Git's bash by its short path, because the
  service account's `bash` and `sh` are the WSL stub; a PowerShell step says `shell: powershell`, not `pwsh`.
- Main that goes green closes its own `ci-red` issue; the `report-green` job comments and closes it.
- The Supabase project is one approved command, `sh scripts/supabase-create.sh NAME`, which writes the password
  only to `.env`; it belongs on the launch to-do, not in a by-hand step.

## 4b. One design source for every platform

A project with a web app and a phone app (web + Android, web + iOS) starts with `design/tokens.json` and `design/icons.json` as the one source of its look, and `node scripts/design/generate.mjs` writing each platform's tables from them: a TypeScript module, a CSS file with one class per type role, a Kotlin object, a Swift enum. Set `outputs` in `tokens.json` to the platforms the project has. One project built this by hand after its second screen drifted; it is a bootstrap output so the next one does not.

Three rules go with it, and CI holds them (`scripts/ci/design-check.sh`, in the `checks` job wherever `design/tokens.json` exists):

1. **A screen uses a token or a role, never a literal.** A pull request that adds a raw hex colour, a px/dp/sp size or a font name to a UI file fails, unless its body says why: `Design: <reason>`. The generated files and `design/` are exempt; `scripts/ci/design-ui.txt` lists the UI globs and `scripts/ci/design-allow.txt` the lines to let through.
2. **Type roles are the unit, not sizes.** `rowClaim: sans 15/1.3 600` is one line both platforms follow; a screen names the role. A decision such as "card text reads in the body sans" is one line in `tokens.json`.
3. **A colour chosen by data is a core rule; a colour chosen by design is a token.** A mood's colour, a state's tone, anything picked by what the data says lives in the shared core with fixtures; the tokens supply the palette it picks from.

Where `scripts/ci/parity.txt` lists screen pairs, the check also fails a pull request whose pair names different type roles on its two sides, and `design/screens.txt` records when a person last compared each pair by eye; the session brief names the pairs never compared or older than 14 days (`sh scripts/design/screens.sh compare NAME` records one).

Where `design/mocks/` holds the project's mocks, `scripts/ci/mocks.txt` maps each screen to them, one line per screen: `NAME UI_PATH MOCK_PATH [MOCK_PATH...]`, globs allowed, listing every file of the mock (the light file, the dark file, the script that generates them). `scripts/ci/mock-check.sh`, in the `checks` job wherever `mocks.txt` exists, fails a pull request that changes a mapped UI file without changing any of its mock files, unless the body says `Mock: unchanged, <reason>`; and a new UI file beside mocked screens that no line names, until a line maps it or `unmocked PATH` declares it. `generator PATH` names a helper every generator shares. The session brief names screens whose mock is more commits behind their UI than `# stale-after: N` in `mocks.txt` (20 by default).

Where `design/mocks/` exists, the words come from the mocks as the look comes from the tokens: `node scripts/design/copy-extract.mjs` writes `design/copy/<screen>.json`, every visible string keyed by its `data-copy` id or a slug of the text (a light and dark pair is one file), and `generate.mjs` writes a strings module per platform from them (`outputs.copyTs`, `copyKotlin`, `copySwift`), so a screen says `copy.home.welcomeBack`, never the words. Both are generated pages. The design check then fails when the copy files are stale against the mocks, and a pull request that adds words to a UI file as a literal, with the same `Design: <reason>` escape; `scripts/ci/copy-allow.txt` names the user-facing calls and the literals allowed.

Where a project can serve its built screens, a line ends in the screen's route (`NAME UI_PATH MOCK.html... @/route`) and `scripts/design/serve.sh` (a commented stub until the project fills it) starts the app with its fixture data and prints its base URL. Then the `screens` job in `ci.yml`, on a pull request that touches a routed screen, renders the mock and the built route side by side in the runner's own headless browser, light and dark, uploads the images, and leaves one comment with the share of pixels that differ; above `# threshold:` (0.05) it flags, never fails. A person looks and records it: `sh scripts/design/screens.sh compare --mock NAME`; the session brief names routed screens never compared with their mock or not in 14 days. `# fixtures: PATH` names the one sample-data file the mocks and the app both read.

## 5. The project board, exactly

Create one GitHub project for the repository and set it up so nothing has to be updated by hand:

- **A State field**, single select, with these eight values: Ready, In progress, Waiting on owner, Waiting on a service, Parked, Dated, After launch, Blocked. Create it with `gh project field-create <number> --owner <owner> --name State --data-type SINGLE_SELECT --single-select-options "Ready,In progress,Waiting on owner,Waiting on a service,Parked,Dated,After launch,Blocked"`. Matching labels on the repository, `state:ready` through `state:blocked`, for the filing hook. Blocked is for a task stopped by something outside its own words; the comment says what.
- **The state labels** are made by `scripts/labels.sh` in the compact form, `state:ready`. A project that already names its own `state: ready` keeps them: every script and workflow reads the repository's labels once and writes whichever form it finds, so no second set appears beside the first.
- **Built-in workflows**, in the project's Workflows tab (the API cannot switch them on, so this is a one-time click each): Auto-add to project with the filter `is:issue is:open` on the repository; Item closed, set Status to Done; Pull request merged, set Status to Done; Auto-add sub-issues to project. Leave Auto-archive off until the board is busy. These act on the board's own Status field; nothing built in moves State.
- **At filing**, the coordinator runs one command (`scripts/state.sh`) that sets the state label, the board's State and the mirrored built-in Status together; the filing hook refuses an issue without a state label.
- **A nightly sync** (`scripts/board-sync.sh`, run by a scheduled workflow an hour before the audit) makes the label and both board fields agree for every issue, with closed issues as Done.
- **The board view**: group by State. That view is the status report; nobody writes one.
- **A nightly audit** (a scheduled workflow) lists open issues with no State, issues still open and Ready after their PR merged, and an open red-main issue, as one comment on a tracking issue, and says nothing when clean.

## 6. Outputs of this skill

Create, in order:
1. The repository with CLAUDE.md and AGENTS.md from sections 1 and 2, short, pointing at the hooks and checks.
2. The issue template with the State field; the project board set up exactly as section 5 says; the labels.
3. `.claude/runners.json` with the runner count, then the runners themselves (`add-runner.ps1`, one elevated prompt each), the doctor and the runner check once, and the runner watch's scheduled task. The hooks, which the plugin provides: block delete, force-push, full sweeps, direct writes to generated pages, issue creation without a state label, a GraphQL call when the hour's budget is nearly spent, agent dispatch without a fitting model, the serial merge of more than two PRs without a named mode, a pull request closed without a comment, a detached worktree; and the stop hook that refuses to finish a task in a worktree that is not clean. Also the project's `.gitignore`, with the scratch folder and the generated files that make a clean folder look dirty.
4. The CI skeleton from section 4: the classifier, the per-class jobs, the `CI passed` summary, the status-page, spec, setup-line and line-endings checks, the full run on main, the merge queue, the nightly audit. Then branch protection with `sh scripts/protect-main.sh`.
5. The setup document, the notice file, the one-screen status page and its build and check scripts.
6. The work folder outside the repo, with a register for research and an off-site backup scheduled.
7. The constitution, then the first spec.
7b. Mocks to specs, when `design/mocks/` exists, between the constitution and the first spec: one `specs/<feature>/` per area of the mocks, each listing its mock screens and, as acceptance criteria, the rules no picture shows (what is saved, who may see it, what happens when it fails). Then `scripts/ci/mocks.txt` mapping each screen to its mock files, and the mock check from section 4b. When `design/tokens.json` does not exist yet, run `node scripts/design/seed-tokens.mjs` to write a draft one from the colours, families, type sizes, radii and spacings the mocks use, each with how often it was seen; `--print` shows it first. The draft is a person's starting point, never the finished look: they name each key for its purpose, merge near-duplicates, drop one-offs and delete the `_draft` note before the first screen is built from it. It never overwrites a tokens file; with one present it writes `design/tokens.draft.json` beside it. With `design/tokens.json` there too, run `node scripts/design/copy-extract.mjs` and `node scripts/design/generate.mjs` once and commit `design/copy/` and the copy module, so screens are built saying copy ids from the first one. Where the app can be served, give each screen its `@/route` and fill in `scripts/design/serve.sh`, so every pull request that touches a screen shows it beside its mock.
8. The owner console: `console/services.json` listing every outside system, the settings each depends on with a plain label, the links, the launch to-do with its flags, and the FAQ; served locally with `node "$CLAUDE_PLUGIN_ROOT/console/cli.js" console`, and mounted online behind the owner sign-in when wanted. Its check fails when a name in the example env file has no card.
8b. Deploys: `sh scripts/deploy-setup.sh` with the path the survey chose, the app's folder and the interval. It writes `vercel.json` in the app's folder and `.claude/deploy.json`, and for the scheduled paths the Deploy workflow's schedule and the `DEPLOY_PATH` variable; name the secrets it lists to the owner, and the console's two Vercel checks (the Standard build machine, a spend cap), which have no API.
9. The session brief's config, `.claude/session-brief.json`: the merge queue's log glob, the agent's memory folder, and the line limit.
10. The drive's config, `.claude/project-drive.json`, and one open issue titled "Drive" labeled `drive`.
11. The queue's published state (spec 001): the repository variable `QUEUE_PUBLISH_STATE` set to `issue` (`gh variable set QUEUE_PUBLISH_STATE --body issue`), and one open issue titled "Merge queue" labeled `queue` and `state:parked`, which the queue rewrites with what it is doing; the owner pins it from its page. `sh scripts/ci/publish-state.sh --print` shows the body before the first write.

The drive is the loop that moves the project between sessions, and it moves it only where a person said to.
There is no goals list; the board and the checks are the goal. One round of `/project-drive` reads the state,
writes a numbered proposal (land these, fix that, start these, ask the owner about this one, set this record
right), and stops. In a session it asks with the question tool; overnight it posts the proposal on the drive
issue. A person answers with the numbers to approve. The next round pursues those and nothing else, asks a
person for any decision that is theirs, files a new issue for anything outside a goal's words, and reports in
one block. The config holds the runner count, the agent and minute budgets per round, the queue log glob, and
the owner's list of what is always theirs.

The brief exists because CLAUDE.md and an agent's memory both describe the past. When a session restarts, to load a
new hook or for any other reason, the agent should see what is true now: what is on main, which pull requests are
open and in what state, whether the queue ran, what is in progress, what the last session handed off, and what
waits on the owner. The plugin's SessionStart hook prints that in one block of at most forty lines. The config
tells it where the queue logs and the memory folder are; without it, the brief still prints the git and gh
sections.

Then the first feature agent runs.

## On an existing project

A repository with history, open pull requests and agents already at work gets the same pieces in a different
order, one pull request per step, so nothing lands all at once and nothing working is replaced by a skeleton.

1. **Survey first**, as above. Name the shared pages that grow by appending and the hand-kept status page; they
   are the symptoms, and they become inputs below.
2. **Hooks on, and the generated-pages list filled in** with the repository's real shared pages, so the next
   append is refused the same day. Tell the team in one message what the six hooks refuse and what to do instead.
3. **Labels and the audit.** The first night's comment will list every open issue with no State. That is the
   backlog, not a failure; work it down over the week.
4. **The status page, mined from what exists.** Write one stub per existing feature from the old status page,
   build STATUS.md, then move the old page aside (`git mv`, never delete) and add it to the generated-pages list
   if anything still points at it.
5. **CI, in this order:** the summary job and the setup check first, since they fail nothing that passes today;
   then the spec check, which is incremental by design (each feature gets its folder when it is next touched);
   then line endings, which is one deliberate normalizing commit made when no pull requests are open, because
   it conflicts with every branch that was cut before it.
   **From day one, not as a later sync:** the `!rerun-free docs specs status` line in `classes.txt`, an empty
   `task-files.txt`, no union merge on any hand-edited file, and every existing task file frozen (each open
   task becomes an issue; one line at the top says so). On one project these four fixed a week of appends to
   shared pages in an evening; put in at the start they prevent it.
6. **The board.** If one exists, give its number to the board script instead of letting it create a second.
7. **The console**, from the example env file the project already has; the check names every setting that
   still has no card, which is the list of systems to describe.

Two files the project may already have deserve a word. **The manual:** keep the one that exists, name it on a
`manual PATH` line in `scripts/ci/setup-paths.txt`, and do not create `SETUP.md` beside it. **The console's
questions:** the sample lists the questions of a project with uploads, claims and an importer; a project with
other flows writes its own ids under `faq.required` and answers those.

Never overwrite. For every template whose file already exists, write the skeleton beside it as
`NAME.bootstrap.md` (or `.bootstrap.yml`, and so on) and leave the merge to a person. The templates are the
shape; the existing file is the truth until someone says otherwise.

## Where the pieces are

When this skill runs from the plugin, the hooks in step 3 are already active and the files for the other steps
are ready to copy from `${CLAUDE_PLUGIN_ROOT}/templates/`:

- Step 1: `CLAUDE.md`, `AGENTS.md`, `.claude/generated-pages.txt`
- Step 2: `.github/ISSUE_TEMPLATE/`, `.github/workflows/state-label.yml`, `.github/workflows/board-sync.yml`, `scripts/labels.sh`, `scripts/board.sh`, `scripts/state.sh`, `scripts/board-sync.sh`, `scripts/board-lib.sh`
- Step 4: `.github/workflows/ci.yml`, `scripts/ci/` (classes, classifier, merge queue, spec, setup and line-endings checks), `.github/workflows/audit.yml`
- Step 5: `SETUP.md`, `NOTICE.md`, `status/` and the `STATUS.md` it builds
- Step 6: nothing in the plugin; it lives outside the repo, so create it by hand and name its path in CLAUDE.md
- Step 7: `specs/constitution.md` and `specs/001-FEATURE/spec.md`, checked by `scripts/ci/spec-check.sh`
- Step 7b: `scripts/ci/mocks.txt` (a commented example), `scripts/ci/mock-check.sh` and `scripts/ci/mock-lib.sh`; `scripts/design/seed-tokens.mjs` and `scripts/design/seed-lib.mjs` for the draft tokens file; for copy, `scripts/design/copy-extract.mjs` and `scripts/ci/copy-allow.txt`; for the side-by-side, `scripts/design/screens-diff.mjs`, `scripts/design/screens-run.sh` and `scripts/design/serve.sh` (a stub the project fills)
- Step 8: `console/services.json` and `.env.example`; the page itself comes from the plugin's `console/` and needs no copy
- Step 3 also: `.gitignore`, with `.scratch/` and the generated files
- Step 3, by hand: `.claude/settings.json`, the allow rules for the deploy dispatch, the merge queue and the project's scripts. This is the one step the person does: the agent is not allowed to grant itself permissions, so it cannot write the file. Tell them so in those words and point them at `node "${CLAUDE_PLUGIN_ROOT}/console/cli.js" permissions`, which they run in a terminal; it merges with any rules already there and opens the pull request. Until then the brief names it as waiting on the owner.
- Step 4 also: `scripts/worktrees.sh` and `scripts/worktrees-lib.sh`, which the merge queue calls to check a pull request's folder when it is queued and to remove a merged branch's worktree and branch; `scripts/ci/shared-check.sh` and `shared-paths.txt`
- Step 9: `.claude/session-brief.json`; the hook comes from the plugin
- Later: the plugin-owned copies go stale as the plugin moves on. `scripts/sync/sync-templates.sh` in the plugin reports which differ or are missing and, with `--apply`, refreshes them on a branch for a pull request. The session brief says when they are out of date.
- Step 10: `.claude/project-drive.json`; the skill and its scripts come from the plugin; the drive issue is filed with `gh issue create --title Drive --label drive,state:parked`

Copy them into the new repository, replace every CAPITALIZED placeholder, run `sh scripts/board.sh OWNER OWNER/REPO`
(it prints the board's address: put that link in your final message to the owner, since the board is the status
report and nobody finds it by hand), run `sh scripts/protect-main.sh` for branch protection, switch on the board's built-in workflows by hand (the one
setting with no API), and build the status page once with `sh status/build.sh`. Adapt a copied template with `sed`
or a short script, never by rewriting the whole file: the Write tool refuses to overwrite a file it has not read,
and a rewrite loses the template's own comments, which are the reasons for its lines. When the project is not on GitHub, say so, use section 0, and keep the pure parts of the scripts.
