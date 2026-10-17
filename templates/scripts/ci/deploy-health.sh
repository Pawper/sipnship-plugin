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
# Reads .claude/deploy.json; uses origin/main as fetched.
here=$(dirname "$0")
. "$here/deploy-lib.sh"
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
deploy_health "$path" "$main" "$deployed" "$oldest" "$(date +%s)" "$interval" "$2"
