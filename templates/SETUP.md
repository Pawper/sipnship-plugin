# Setup

The one manual for this project. It holds what a person or an agent needs to run the project from a clean machine: configuration, the names of keys, and the migrations that have been run. It never holds anything that changes per feature; that belongs in the feature's spec and its status stub.

When a PR changes a setup step, it changes the line here in the same PR.

## Requirements

- RUNTIME and version
- DATABASE and version
- Any tool a developer must install by hand

## Configuration

Every value comes from the environment. List the name, what it is for, and where the value lives. Never the value itself.

| Name | What it is for | Where it lives |
|---|---|---|
| `DATABASE_URL` | The main database | The team password manager, entry PROJECT_NAME |
| `SERVICE_API_KEY` | Access to SERVICE | The team password manager, entry PROJECT_NAME |
| `QUEUE_PUBLISH_STATE` | `issue`: the merge queue rewrites the "Merge queue" issue with its state; unset or `off`: it does not | A repository variable (Settings, Secrets and variables, Actions, Variables) |

## First run

1. Clone the repository and install the dependencies with `INSTALL_COMMAND`.
2. Copy `.env.example` to `.env` and fill in the names above.
3. Run the migrations with `MIGRATE_COMMAND`.
4. Start the app with `START_COMMAND`.
5. Add the agent's permissions yourself: run `node console/cli.js permissions` from the plugin in a terminal (the agent is not allowed to grant itself permissions). It writes `.claude/settings.json`, opens the pull request, and asks you to restart the session.

## Migrations run

One line per migration, in order, with the date it ran in production. The newest line is at the bottom.

| Migration | Ran in production |
|---|---|
| `0001_initial` | YYYY-MM-DD |

## Services

| Service | What it does for us | Status page |
|---|---|---|
| SERVICE | One line | URL |

## Deploys

How main reaches production, written by `sh scripts/deploy-setup.sh` into `.claude/deploy.json`. Build CPU is most of a Vercel bill, so nothing builds a branch, nothing builds for a change that does not ship, and at most one deploy runs per interval.

| Setting | Value |
|---|---|
| Path | DEPLOY_PATH: `runner` (built on our runner, deployed prebuilt), `vercel` (a scheduled deploy Vercel builds) or `guard` (Git deploys from main, skipped when nothing ships, throttled) |
| App folder | APP_ROOT |
| Interval | INTERVAL minutes |
| Secrets, for `runner` and `vercel` | `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`; optional `ADMIN_TOKEN` |
| Build machine | Standard, in the Vercel project's settings |
| Spend cap | Set in the Vercel team's billing |

To deploy now: run the Deploy workflow from the Actions tab (`runner`, `vercel`), or push to main (`guard`).
