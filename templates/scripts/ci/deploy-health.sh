#!/bin/sh
# Print one line when the project's deploy path is not keeping up, nothing
# when it is or when the project has no deploy path. The session brief and
# the nightly audit both run it, so they never disagree.
#
# Usage: sh scripts/ci/deploy-health.sh [DEPLOYED_SHA] [LAST_RUN_CONCLUSION]
#   DEPLOYED_SHA  the commit in production; read from refs/deploy/production
#                 (the scheduled paths record it) when not given. The guard
#                 path has no such ref; the audit passes the sha Vercel
#                 reports when VERCEL_TOKEN is set.
#   LAST_RUN_CONCLUSION  the Deploy workflow's last conclusion ("fellback"
#                 for a runner build that fell back to Vercel). When not
#                 given and gh is signed in, the last run is read here, one
#                 REST call, plus its jobs' annotations when it failed: a
#                 job GitHub refused to start for billing fails with no
#                 step run and says so only there. The release workflows
#                 listed in .claude/deploy.json are read the same way, so a
#                 release skipped for billing is said and not silent.
# Reads .claude/deploy.json; uses origin/main as fetched.
here=$(dirname "$0")
. "$here/deploy-lib.sh"
. "$here/run-lib.sh"

# last_run WORKFLOW_FILE: "ID<TAB>CONCLUSION" of its newest run, or nothing.
last_run() {
  gh api "repos/{owner}/{repo}/actions/workflows/$1/runs?per_page=1" --jq '.workflow_runs[0] | "\(.id)\t\(.conclusion // "")"' 2>/dev/null | tr -d '\r'
}
# run_billing RUN_ID: "yes" when one of the run's jobs was refused for billing.
run_billing() {
  rb_ann=""
  for rb_job in $(gh api "repos/{owner}/{repo}/actions/runs/$1/jobs?per_page=10" --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "startup_failure") | .id' 2>/dev/null | tr -d '\r' | head -n 3); do
    rb_ann="$rb_ann $(gh api "repos/{owner}/{repo}/check-runs/$rb_job/annotations" --jq '[.[].message] | join("; ")' 2>/dev/null)"
  done
  billing_refused "$rb_ann"
}
[ -f .claude/deploy.json ] || exit 0
cfg=$(cat .claude/deploy.json)
path=$(json_string "$cfg" path)
app=$(json_string "$cfg" appRoot); [ -n "$app" ] || app=.
interval=$(json_number "$cfg" intervalMinutes); [ -n "$interval" ] || interval=60
extra=$(json_words "$cfg" neverShips)

main=$(git rev-parse -q --verify origin/main 2>/dev/null || git rev-parse HEAD)
deployed=$1
if [ -z "$deployed" ] && [ "$path" != guard ]; then
  deployed=$(git ls-remote origin refs/deploy/production 2>/dev/null | cut -f1)
fi

# When the oldest commit on main that ships, and is not in production, landed.
oldest=""
if [ -n "$deployed" ] && [ "$deployed" != "$main" ] && git cat-file -e "$deployed^{commit}" 2>/dev/null; then
  for c in $(git rev-list --reverse "$deployed..$main" 2>/dev/null); do
    if [ "$(deploy_skip "$(git diff-tree --no-commit-id --name-only -r -m "$c" 2>/dev/null)" "$app" "$extra")" = build ]; then
      oldest=$(git log -1 --format=%ct "$c"); break
    fi
  done
  # Everything since the deployed commit is docs and the like: in step.
  [ -n "$oldest" ] || deployed=$main
fi
last_conc=$2
if [ -z "$last_conc" ] && [ "$path" != guard ] && [ -f .github/workflows/deploy.yml ] && command -v gh >/dev/null 2>&1; then
  lr=$(last_run deploy.yml); last_conc=${lr#*	}
  case "$last_conc" in failure|startup_failure) [ "$(run_billing "${lr%%	*}")" = yes ] && last_conc=billing ;; esac
fi
deploy_health "$path" "$main" "$deployed" "$oldest" "$(date +%s)" "$interval" "$last_conc"
# A listed release that GitHub refused to start for billing: one line each.
if command -v gh >/dev/null 2>&1; then
  for rel in $(release_workflows "$cfg"); do
    lr=$(last_run "$rel")
    case "${lr#*	}" in failure|startup_failure)
      if [ "$(run_billing "${lr%%	*}")" = yes ]; then billing_line "the release workflow $rel"; fi ;;
    esac
  done
fi
