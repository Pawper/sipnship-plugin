#!/bin/sh
# Set up how this project deploys to Vercel so build CPU stays down: no
# branch builds, nothing for changes that do not ship, at most one deploy
# per interval. Writes vercel.json in the app's folder (merging into one
# that exists, so crons and other keys stay) and .claude/deploy.json, and
# for the scheduled paths sets the repository variables the Deploy
# workflow reads. It never edits the workflow, so the sync can keep it
# current.
#
# Usage: sh scripts/deploy-setup.sh [PATH] [APP_ROOT] [INTERVAL_MINUTES]
#   PATH      runner, vercel or guard; omitted or "", it is chosen from
#             what the project has.
#   APP_ROOT  the app's folder, "." by default; "web" in a monorepo.
#   INTERVAL  minutes between deploys at most: 60 by default on the
#             scheduled paths; on the guard path 0 (no throttle) by
#             default, since a throttled build waits for the next push and
#             the day's last merge would not ship.
# Environment:
#   DEPLOY_HOSTED=yes|no   whether GitHub's hosted machines are available;
#                          by default yes for a public repository, no for a
#                          private one, which often has no hosted minutes.
#   DEPLOY_NEVER_SHIPS     the app's own folders that never ship, space
#                          separated ("packs scripts"); kept in
#                          .claude/deploy.json as "neverShips".
# Needs node (to edit JSON) and, to choose the path or set variables, gh
# signed in. It commits nothing; review the diff and open a PR.
set -e
here=$(dirname "$0")
. "$here/ci/deploy-lib.sh"
path=$1; app=${2:-.}; interval=$3
app=${app%/}; [ -n "$app" ] || app=.
[ -d "$app" ] || { echo "No folder $app; give the app's folder as the second argument." >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node is needed to edit vercel.json." >&2; exit 2; }
# gh only with a GitHub remote: without one, gh asks which repository and
# waits for an answer nobody gives.
have_gh=no
case "$(git remote get-url origin 2>/dev/null)" in
  *github.com*) command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && have_gh=yes ;;
esac

# What the project has: a runner that is not Windows, the secrets, hosted
# machines. Read once, used to choose the path and where its jobs run.
runners=""; secrets=no
if [ "$have_gh" = yes ]; then
  runners=$(gh api 'repos/{owner}/{repo}/actions/runners' --jq '.runners[] | [.os, ([.labels[].name] | join(","))] | @tsv' 2>/dev/null || true)
  names=$(gh api 'repos/{owner}/{repo}/actions/secrets' --jq '.secrets[].name' 2>/dev/null || true)
  printf '%s\n' "$names" | grep -qx VERCEL_TOKEN && printf '%s\n' "$names" | grep -qx VERCEL_ORG_ID && printf '%s\n' "$names" | grep -qx VERCEL_PROJECT_ID && secrets=yes
fi
pick=$(runner_os_pick "$runners")
runner=no; [ -n "$pick" ] && runner=yes
hosted=${DEPLOY_HOSTED:-}
if [ -z "$hosted" ]; then
  hosted=yes
  [ "$have_gh" = yes ] && [ "$(gh api 'repos/{owner}/{repo}' --jq .private 2>/dev/null)" = true ] && hosted=no
fi

if [ -z "$path" ]; then
  path=$(deploy_path yes "$runner" "$secrets" "$hosted")
  echo "Chose the $path path (a Linux or macOS runner: $runner; the Vercel secrets: $secrets; hosted machines: $hosted)."
  if [ "$runner" = no ] && [ -n "$runners" ]; then
    echo "The runners here are Windows, which cannot take the runner path: a Windows build cannot write the output without Developer Mode, and with it Vercel rejects the upload."
  fi
fi
case "$path" in runner|vercel|guard) ;; *) echo "PATH is runner, vercel or guard." >&2; exit 2 ;; esac
if [ "$path" = runner ] && [ "$runner" = no ] && [ -n "$runners" ]; then
  echo "Refusing the runner path: every runner here is Windows, and a Windows build cannot deploy to Vercel. Use vercel (needs hosted machines or a Linux runner) or guard." >&2
  exit 2
fi
if [ "$path" = vercel ] && [ "$hosted" = no ] && [ "$runner" = no ]; then
  echo "Refusing the vercel path: with no hosted minutes and no Linux or macOS runner, nothing can run the Deploy workflow. Use guard, which needs no workflow, or set DEPLOY_HOSTED=yes if hosted minutes exist." >&2
  exit 2
fi

[ -n "$interval" ] || { if [ "$path" = guard ]; then interval=0; else interval=60; fi; }
rel=$(rel_to_root "$app")
DS_FILE="$app/vercel.json" DS_PATH="$path" DS_CMD="sh ${rel}scripts/ci/vercel-ignore.sh" node -e '
  const fs = require("fs");
  const f = process.env.DS_FILE;
  let j = {};
  try { j = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { if (fs.existsSync(f)) { console.error("vercel.json is not valid JSON; fix it first."); process.exit(1); } }
  if (!j.$schema) j = { $schema: "https://openapi.vercel.sh/vercel.json", ...j };
  j.git = j.git || {};
  if (process.env.DS_PATH === "guard") {
    j.git.deploymentEnabled = { main: true, "*": false, "**": false };
    j.ignoreCommand = process.env.DS_CMD;
  } else {
    j.git.deploymentEnabled = false;
    delete j.ignoreCommand;
  }
  fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
'
never=""
for w in ${DEPLOY_NEVER_SHIPS:-}; do never="$never${never:+, }\"$w\""; done
mkdir -p .claude
printf '{\n  "_comment": "How this project deploys, written by scripts/deploy-setup.sh. path: runner, vercel or guard. neverShips: the app'"'"'s own folders that never ship, besides the homes the plugin knows. The Deploy workflow, the Vercel ignore step, the brief and the audit read it. intervalMinutes 0: deploy after every landing unless another pull request is green.",\n  "path": "%s",\n  "appRoot": "%s",\n  "intervalMinutes": %s,\n  "neverShips": [%s]\n}\n' "$path" "$app" "$interval" "$never" > .claude/deploy.json
echo "Wrote $app/vercel.json and .claude/deploy.json."

if [ "$path" = guard ]; then
  echo "Git deploys now come from main only and skip changes that do not ship."
  if [ "$interval" -gt 0 ] 2>/dev/null; then
    echo "Set DEPLOY_INTERVAL_MINUTES=$interval in the Vercel project's environment variables to throttle builds to one per $interval minutes."
    echo "The throttle's risk: a skipped build waits for the next push to main, so the day's last merge may not ship until the next one. Set VERCEL_TOKEN, VERCEL_ORG_ID and VERCEL_PROJECT_ID as repository secrets so the nightly audit can say when main is undeployed."
  fi
  echo "The Deploy workflow, if present, does nothing on this path."
  echo "No secrets are needed. Commit both files and open a pull request; Vercel reads them on the next push to main."
  exit 0
fi

setvar() {
  if [ "$have_gh" = yes ] && gh variable set "$1" --body "$2" >/dev/null 2>&1; then echo "Set the repository variable $1 to $2."
  else echo "Set the repository variable $1 to $2 by hand (Settings, Secrets and variables, Actions, Variables)."; fi
}
setvar DEPLOY_PATH "$path"
# The plan and the Vercel-built deploy run where ci.yml's jobs run (the
# RUNS_ON and RUN_SHELL the sync fills), so there is no variable to set.
[ "$path" = runner ] && setvar DEPLOY_RUNNER "$pick"
[ -f .github/workflows/deploy.yml ] || echo "Add .github/workflows/deploy.yml: the sync does it with --only deploy."
cat <<EOF
Before the first scheduled run, set three repository secrets (Settings, Secrets and variables, Actions):
  VERCEL_TOKEN       a token from vercel.com/account/tokens
  VERCEL_ORG_ID      and VERCEL_PROJECT_ID, from .vercel/project.json after "npx vercel link"
Optional: ADMIN_TOKEN, so the plan can see whether a runner is online.
Then run the Deploy workflow once from the Actions tab; it records the deployed commit.
Vercel's Git deploys are off from the moment vercel.json reaches main; until the Deploy workflow runs, main is not deployed.
EOF
