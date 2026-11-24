#!/bin/sh
# Deploy main from this clean copy of it, on this machine, around GitHub's
# runs: the Deploy workflow's own steps, behind the same gate, ending with
# the same record, refs/deploy/production. The plugin's listener runs it for
# a "deploy-here" request, in a fresh copy of origin/main it removes after;
# by hand, run it from a clean copy of main (a worktree) after signing in to
# gh and wrangler.
#   sh scripts/ci/deploy-here.sh
# Exits 0 when main is in production (deployed now, or already), 1 when the
# gate holds it or a step fails; every line says why.
here=$(dirname "$0")
. "$here/deploy-lib.sh"
cfg=$(cat .claude/deploy.json 2>/dev/null || true)
app=$(json_string "$cfg" appRoot); app=${app:-.}
target=$(json_string "$cfg" target); target=${target:-cloudflare}
workers=$(json_words "$cfg" workers)
sha=$(git rev-parse HEAD)
[ "$target" = cloudflare ] && [ -n "$workers" ] || { echo "This project's .claude/deploy.json does not name a Cloudflare target with workers."; exit 1; }
record() {
  gh api -X PATCH "repos/{owner}/{repo}/git/refs/deploy/production" -f sha="$sha" -F force=true > /dev/null 2>&1 \
    || gh api -X POST "repos/{owner}/{repo}/git/refs" -f ref=refs/deploy/production -f sha="$sha" > /dev/null
}
deployed=$(git ls-remote origin refs/deploy/production | cut -f1)
if [ "$deployed" = "$sha" ]; then echo "main ($sha) is already in production."; exit 0; fi
if [ -n "$deployed" ] && git cat-file -e "$deployed^{commit}" 2>/dev/null; then
  if [ "$(deploy_skip "$(git diff --name-only "$deployed" "$sha")" "$app" "$(json_words "$cfg" neverShips)" "$(json_words "$cfg" alsoShips)")" = skip ]; then
    echo "Nothing the app ships changed since $deployed; recording $sha as deployed without a build."
    record; exit 0
  fi
fi
# The gate the Deploy workflow's plan step and the queue use; held means another green change lands first.
sh "$here/deploy-gate.sh" || { echo "The deploy gate holds this deploy; land the green changes first."; exit 1; }
if [ -f pnpm-lock.yaml ]; then
  pv=$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"pnpm@\([^"+]*\).*/\1/p' package.json 2>/dev/null | head -1); pv=${pv:-9}
  { corepack enable 2>/dev/null && corepack prepare "pnpm@$pv" --activate && pnpm install --frozen-lockfile; } || npx --yes "pnpm@$pv" install --frozen-lockfile || exit 1
fi
if ls packages/service/migrations/*.sql >/dev/null 2>&1; then (cd packages/service && npx wrangler d1 migrations apply DB --remote) || exit 1; fi
for w in $workers; do
  echo "Deploying the Worker in $w."
  if grep -q '"assets"[[:space:]]*:' "$w/package.json" 2>/dev/null; then (cd "$w" && npm run assets) || exit 1; fi
  (cd "$w" && deploy_with_retry) || exit 1
done
record
echo "main ($sha) is in production."
