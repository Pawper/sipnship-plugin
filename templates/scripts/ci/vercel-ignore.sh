#!/bin/sh
# Vercel's "Ignored Build Step" for the guard path: exit 0 skips the build,
# exit 1 builds. vercel.json runs it from the app's folder, and its
# git.deploymentEnabled already limits Git deploys to main.
#
# It diffs from VERCEL_GIT_PREVIOUS_SHA, the last commit Vercel deployed,
# not HEAD^..HEAD: a build skipped for being docs-only, or for the
# throttle, is then shipped by the next build, so no change is lost. It
# skips when nothing the app ships changed, and, when the Vercel project
# sets DEPLOY_INTERVAL_MINUTES, when the last production deploy was less
# than that ago. The throttle is off by default: a skipped build waits for
# the next push to main, and on a quiet evening the last merge of the day
# would never ship. With the throttle on, the nightly audit says when main
# is undeployed (with VERCEL_TOKEN set).
here=$(cd "$(dirname "$0")" && pwd)
. "$here/deploy-lib.sh"

ref=${VERCEL_GIT_COMMIT_REF:-}
if [ -n "$ref" ] && [ "$ref" != main ]; then echo "Not main ($ref): skipped; only main deploys."; exit 0; fi

prev=${VERCEL_GIT_PREVIOUS_SHA:-}
[ -n "$prev" ] || { echo "No previous deployment recorded: building."; exit 1; }
if ! git cat-file -e "$prev^{commit}" 2>/dev/null; then
  git fetch -q --deepen=200 2>/dev/null || true
  git cat-file -e "$prev^{commit}" 2>/dev/null || { echo "The last deployed commit $prev is not in this clone: building, to be safe."; exit 1; }
fi

app=$(git rev-parse --show-prefix 2>/dev/null); app=${app%/}; [ -n "$app" ] || app=.
top=$(git rev-parse --show-toplevel)
paths=$(cd "$top" && git diff --name-only "$prev" HEAD)
extra=$(json_words "$(cat "$top/.claude/deploy.json" 2>/dev/null)" neverShips)
if [ "$(deploy_skip "$paths" "$app" "$extra")" = skip ]; then
  echo "Nothing the app ships changed since $prev: skipped."
  exit 0
fi

last=$(git log -1 --format=%ct "$prev" 2>/dev/null)
if [ "${DEPLOY_INTERVAL_MINUTES:-0}" -gt 0 ] 2>/dev/null; then
  t=$(deploy_throttle "$last" "$(date +%s)" "$DEPLOY_INTERVAL_MINUTES")
  case "$t" in
    wait*) echo "The last deploy was under $DEPLOY_INTERVAL_MINUTES minutes ago: skipped; the next push to main after ${t#wait } minute(s) ships this too."; exit 0 ;;
  esac
fi
echo "The app changed since $prev: building."
exit 1
