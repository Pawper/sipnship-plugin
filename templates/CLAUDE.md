# PROJECT_NAME

One line on what this project is. Replace every CAPITALIZED placeholder.

Many agents work here at once. Each kind of thing has one home, every rule has something that enforces it, and nothing is appended to a shared page.

## Stack

- Issues and board: GitHub. CI: GitHub Actions. Agent runtime: Claude Code.
- One-file test command: `TEST_COMMAND path/to/file`. Generated pages: `STATUS.md`.
- Specs: by hand in `specs/<feature>/`. Work folder: WORK_FOLDER, backed up to BACKUP_LOCATION. Worktrees: WORKTREE_DIR.
- Dates are the owner's local day, TIMEZONE (an IANA name such as America/Los_Angeles). gh output, runner logs and `date -u` are UTC; convert before writing a date anywhere, including a memory note.

## Homes

| Kind | Home | Never |
|---|---|---|
| Work, decisions, priorities | GitHub issues, one per task, filed before an agent starts; the PR closes it; decisions are comments on it | status files, TODO lists in the repo |
| Status at a glance | The project board, fed by GitHub's own automation and the State label set at filing | a hand-kept status page |
| Orientation for an agent starting cold | `STATUS.md`, generated from one stub per feature in `status/stubs/` and checked in CI | per-day or per-item diaries |
| Data | The database, through the app's admin; seed files in `SEED_DIR/` only as input to the importer, one file per unit | hand-written copies of data in prose |
| Research and findings | The work folder outside the repo at WORK_FOLDER, backed up off-site | the docs folder |
| Coordination state (what merged when, what was uploaded) | git history, CI, the storage bucket | written down by hand |
| The manual | `SETUP.md`: configuration, keys by name, migrations run | anything that changes per feature |
| Design | `specs/NNN-feature/`, numbered in order and written before building | design notes in issues only |
| Credit for borrowed code or content | `NOTICE.md` | per-item narrative |

## Rules

- File the issue first, with a State label. Work in an isolated worktree. Never force-push. Never delete; move aside.
- Nothing is appended to a shared page. A PR names its spec in its body (`Spec: specs/<feature>`) and changes the spec only when the design changed; it changes `SETUP.md` only when a person must do a setup step; it changes a feature's status stub only when that feature's state changes; it adds no task to any file, because tasks are issues.
- Tests prove the change and run per file. The full suite is the gate on main, not on the PR.
- Everything a person sees is calm and plain, never a developer note: no issue numbers, fields or migrations in user-facing text.
- GitHub gives the hour 5,000 GraphQL points, shared by every agent and the queue, and `gh issue`, `gh pr`, `gh project` and `gh search` all spend them; a secondary limit on concurrent GraphQL calls trips earlier still. The session brief prints the budget as one line, and `sh scripts/gh-budget.sh` prints it on demand. File issues with `sh scripts/issue-open.sh "TITLE" .scratch/body.md state:ready`, open pull requests with `sh scripts/pr-open.sh`, read checks with `sh scripts/pr-checks.sh N`, and read one issue or pull request with `gh api repos/{owner}/{repo}/issues/N`: all REST, which has its own budget. One queue process at a time; no loop of your own around it; when the budget is low or a call is refused for its rate limit, wait for the reset the line names, never retry at once, and never poll. The board scripts need GraphQL and belong to the coordinator.
- Every date written here is the owner's local day, named in the Stack section above; the session brief prints today. A UTC timestamp from gh or a runner log is converted first, or an evening's work is dated tomorrow.
- Report what was not done and why, not only what was. Say which commands were refused.
- No wait loops; bounded commands; stop every shell when done.
- The plugin's scripts live at the path the session brief prints on its "Plugin:" line. `$CLAUDE_PLUGIN_ROOT` is set for hooks but empty in the Bash tool, so use that path in commands.
- At session start, reply from the session brief. Never run one network call per branch, worktree or issue in the foreground; one call for the whole board is `sh "$CLAUDE_PLUGIN_ROOT/hooks/scripts/board-now.sh"`. Count long lists, do not print them.
- A clean folder is part of done. Before you report finished or open a pull request, `git status` shows nothing outside `.scratch/`. Commit the files, or list them in the pull request as deliberately left out.
- One scratch folder, `.scratch/`, which git ignores. Probe scripts, screenshots and notes go there and nowhere else, so any other untracked file means real work. Stage with `git add -A`; `git add .scratch` fails because the folder is ignored, and that is right.
- Images and build output never go in a worktree. They belong in the work folder outside the repository. The production build runs in CI's `app` job on every pull request that touches the app; to build by hand, build in the batch worktree or a copy under `.scratch/`, never in a task's worktree.
- A screen uses a token or a type role by name, never a literal colour, size or font; the look lives in `design/tokens.json` and is generated into every platform (`node scripts/design/generate.mjs`). A type role is the unit: a screen says `type-rowClaim` or `DesignType.RowClaim`, and the size lives in the tokens. A colour chosen by data is a core rule, with fixtures; a colour chosen by design is a token.
- A fix to shared code gets its own issue and its own pull request. Never patch shared code to get your own build through and ship only your part.
- Stop what you started. Any server or watcher you started from a worktree ends before you finish. Never stop a build daemon (`gradlew --stop`, `nx reset`): it is shared by every build on the machine, including a self-hosted runner's job in flight.
- Never move a branch from outside its worktree, never add a detached worktree, and never close a pull request without a comment saying why or what replaced it; `sh scripts/worktrees.sh close PR "reason"` does the whole ending.
- Open a pull request with `sh scripts/pr-open.sh "TITLE" .scratch/body.md` and read its checks with `sh scripts/pr-checks.sh N`; both use REST. The body follows `.github/pull_request_template.md`: `Closes #N`, `Spec: specs/<feature>`, and, only when a check asks, `Parity: #<open issue>` or `Parity: none, <reason>`, or `Design: <reason>`, written exactly so. `gh pr create` and `gh pr checks` go through GraphQL, whose secondary limit trips first when many agents work at once.
- A new worktree needs its packages before its first test: run the install (`npm ci` in each package with a lockfile) right after `git worktree add`. A first test run without it writes outside the repository.
- Merge only through the queue: `sh scripts/ci/merge-queue.sh --drain` merges everything green, `--serial PR` one pull request. A direct `gh pr merge` is refused.
- A decision is one file in `docs/decisions/`, made with `sh scripts/decisions.sh new "what was decided"`, never a row appended to a table in the brief; `sh scripts/decisions.sh list` prints them all. A brief that still holds a decisions table is moved once with `sh scripts/decisions.sh split`.
- Never take a running number in a shared place. A task, a setup step or a note is named by its issue number ("#123"), which never collides. A file that must keep its order, such as a migration, takes its number from `sh scripts/next-number.sh migration`, which checks main and every open pull request.
- A change that adds a migration merges after the migration has run: run it, mark its line Done in the manual on the same branch, then queue it.
- To act in another folder, use `git -C PATH ...` rather than `cd PATH && git ...`; a `cd` inside a chained command asks for approval every time.
- Worktrees live in one folder, WORKTREE_DIR, and go when their pull request merges. The merge queue removes them; `sh scripts/worktrees.sh prune --apply` clears a backlog. It is the one cleanup allowed, because the branch keeps the work.

## What enforces each rule

| Rule | Enforced by |
|---|---|
| Never delete | The `block-delete` hook refuses rm, del, Remove-Item and git clean |
| Never force-push | The `block-force-push` hook refuses any forced push |
| Tests per file | The `block-full-test-sweep` hook refuses a bare test command; CI runs the full suite on main |
| Nothing appended to a generated page | The `block-generated-page` hook refuses direct edits to the pages in `.claude/generated-pages.txt`; `sh status/check.sh` fails in CI when `STATUS.md` is stale |
| Every issue has a State | The issue template requires it; the `require-state-label` hook refuses `gh issue create` without `--label state:...` and the REST form without `labels[]=state:...`; the `state-label` workflow keeps the label in step with the field; `sh scripts/state.sh` sets it on the board |
| The API budget lasts the hour | The `require-gh-budget` hook refuses a GraphQL `gh` command when fewer than 500 of the hour's points are left, naming the reset; the brief prints the budget; `scripts/issue-open.sh`, `pr-open.sh` and `pr-checks.sh` are REST |
| A red main is seen | The `full` CI job opens an issue labeled `ci-red` when it fails |
| No usage wasted on dispatch | The `require-agent-model` hook refuses an agent or workflow dispatch without a model that fits the task |
| Merging never outlasts the work | The `require-batch-merge` hook refuses a direct `gh pr merge` and more than two PRs through the queue without `--batch`, `--serial` or `--drain`; the queue refuses a change whose migration has not run; see `scripts/ci/QUEUE.md` |
| Numbers never collide | The `numbering-check` step of the `checks` CI job fails when two numbered files share a number or a task file gains a running number; `scripts/next-number.sh` reserves the next free one |
| Runners never fail quietly | The hourly `runner-watch` workflow comments on the audit issue when a runner is offline, fewer than two are online, or a run sits queued for ten minutes; see `scripts/ci/RUNNERS.md` |
| A clean folder is part of done | The `require-clean-worktree` hook refuses to finish a task in a worktree with files outside `.scratch/`, stray images or build output, a process still running from it, or, at the session's end, any script this session started and left running; the merge queue refuses a pull request whose worktree is not clean |
| Shared code changes alone | The `shared-check` step of the `checks` CI job fails a pull request that edits a path in `scripts/ci/shared-paths.txt` together with other work |
| Work always has an ending | The `block-loose-ends` hook refuses `gh pr close` without a comment and a detached worktree; `scripts/worktrees.sh` removes ended worktrees and their branches, keeping a closed branch's commits under a `closed/` tag; the nightly audit reports branches left on the remote after their pull request ended |
| A session starts from facts | The `session-brief` hook prints main, open PRs, the queue, what is in progress, the last handoff and what waits on the owner at every session start; `.claude/session-brief.json` tells it where to look |
| A setup change carries its line | The `setup-check` step of the `checks` CI job fails a PR that changes a file in `scripts/ci/setup-paths.txt` without changing `SETUP.md` |
| A source change belongs to a spec | The `spec-check` step of the `checks` CI job fails a PR that changes a source root (`src/`, or the folders in `scripts/ci/spec-roots.txt`) without naming its spec in the body or changing a `specs/<feature>/` folder; the queue ignores moves on main in the `docs`, `specs` and `status` classes, so naming a spec never costs another PR a re-run |
| The look has one source | The `design` step of the `checks` CI job fails a PR that adds a raw colour, size or font to a UI file, that leaves a generated design file stale, or whose screen pair names different type roles on its two platforms; the brief names screen pairs not compared by eye in 14 days |
| Line endings stay LF | `.gitattributes` forces it and the `line-endings` step of the `checks` CI job fails on any CRLF file |
| Nothing drifts quietly | The nightly `audit` workflow comments on the issue labeled `audit` when an issue has no State, a merged PR left one stale, or a red-main issue is still open, and says nothing when clean |

Two rules have no mechanical check and are reviewed by hand: report what was not done and which commands were refused, and stop every shell when done.

## Not on GitHub?

These files were written for GitHub, Actions and `gh`. If this project uses something else, say so once, keep every rule, and swap the tool: the tracker's issue with a State field, its board grouped by State, its CI with the same jobs, its CLI in the scripts. The pure parts of every script are tool-free.

The hooks come from the `sipnship` plugin, SipNShip's free local part. If a hook refuses a command, do what its message says; do not look for a way around it.

## Commands

- Build the status page: `sh status/build.sh`
- Check it is current: `sh status/check.sh`
- Run one test file: `TEST_COMMAND path/to/file`
- Classify a change: `sh scripts/ci/classify.sh`
- Regenerate the design tables from `design/tokens.json`: `node scripts/design/generate.mjs` (`--check` in CI); record a cross-platform screen comparison: `sh scripts/design/screens.sh compare NAME`
- Open the owner console: `node "$CLAUDE_PLUGIN_ROOT/console/cli.js" console`; check its config: `node "$CLAUDE_PLUGIN_ROOT/console/cli.js" console --check`. Adding a service means adding an entry to `console/services.json`.
- Where every open issue and pull request really stands: `/project-status`. Light readers summarize bodies and comments, only for items that changed; you keep one line per item. Do not read the item files yourself.
- Propose the next round: `/project-drive`. It reads the board and the checks, proposes, and does nothing until a person approves in the session or on the issue labeled `drive`. Config in `.claude/project-drive.json`.
