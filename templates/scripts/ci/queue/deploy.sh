#!/bin/sh
# After a landing: whether anything that ships changed, the release
# workflows, and the deploy. Sourced by scripts/ci/merge-queue.sh; functions only.

# ships_since FROM TO: "skip" when nothing that ships changed between the
# two commits, by the Deploy workflow's own rule. The one ask every deploy
# decision makes: the drain's end and a "Deploy now" request alike.
ships_since() { sh "$here/deploy-gate.sh" --ships "$1" "$2" 2>/dev/null; }

# start_releases WHY: the release workflows listed in .claude/deploy.json,
# each started once, unless "releaseOn" is "ask" and WHY is a landing, or
# the workflow is turned off. A turned-off release is a decision, not an
# error: one project holds releases until its owner says go, and the queue
# once tried to start both after an unrelated merge.
start_releases() {
  sr_cfg=$(cat .claude/deploy.json 2>/dev/null)
  sr_on=$(release_on "$sr_cfg")
  for sr_f in $(release_workflows "$sr_cfg"); do
    sr_state=$(gh api "repos/{owner}/{repo}/actions/workflows/$sr_f" --jq .state 2>/dev/null) || sr_state=""
    sr_why=$(release_hold "$sr_state" "$sr_on" "$1")
    if [ -n "$sr_why" ]; then say "release held: $sr_f $sr_why"; continue; fi
    gh_write api -X POST "repos/{owner}/{repo}/actions/workflows/$sr_f/dispatches" -f ref="$base" >/dev/null 2>&1 \
      && say "Started the release workflow $sr_f." || say "Could not start $sr_f; run it from the Actions tab."
  done
}

# Defined before the drain, which calls it at its end: defined after it,
# the drain ended "deploy_if_due: command not found" (exit 127) every time.
# deploy_if_due BEGIN_SHA: after a landing, the same in every mode. When main
# moved since BEGIN_SHA and the project deploys on a schedule, start the
# Deploy workflow now rather than at the next hour; the guard path deploys
# from Git by itself. Release channels (store uploads, test distributions)
# follow Deploy; where no Deploy run starts them, the ones listed under
# "releases" in .claude/deploy.json are started here, once. A --serial
# run once ended "queue done" with no deploy started: only the drain did this.
deploy_if_due() {
  d_end=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
  if [ "$d_end" = "$1" ]; then say "Nothing merged, so nothing to deploy."; return 0; fi
  [ -f .claude/deploy.json ] || { say "No .claude/deploy.json; main deploys on its own."; return 0; }
  # The gate: no other green pull request waiting, and the interval passed.
  # A pull request this drain tried and left open never holds it, and the
  # hold is bounded by the drains in a row that held it (a repository
  # variable) and by QUEUE_DEPLOY_MAX_HOLD.
  d_held=$(gh api "repos/{owner}/{repo}/actions/variables/QUEUE_DEPLOY_HELD" --jq .value 2>/dev/null | tr -dc '0-9'); d_held=${d_held:-0}
  if gate=$(QUEUE_DEPLOY_SKIP="${tried:-}" QUEUE_DEPLOY_HELD_DRAINS="$d_held" sh "$here/deploy-gate.sh" "$base" 2>/dev/null); then
    [ "$d_held" = 0 ] || set_repo_var QUEUE_DEPLOY_HELD 0 || true
  else
    case "$gate" in *"green PR"*) set_repo_var QUEUE_DEPLOY_HELD "$((d_held + 1))" || true ;; esac
    say "${gate:-deploy: held} (the Deploy workflow's own dispatch in Actions forces one)"; return 0
  fi
  # Nothing that ships changed since the last deploy (or since this run
  # began, when none is recorded): start nothing. A template sync that
  # touched only scripts/ci and workflows once started a web build and two
  # Android builds. A later landing that ships deploys everything since.
  git fetch -q origin "$base" 2>/dev/null || true
  d_from=$(git ls-remote origin refs/deploy/production 2>/dev/null | cut -f1)
  if [ -z "$d_from" ] || ! git cat-file -e "$d_from^{commit}" 2>/dev/null; then d_from=$1; fi
  if [ "$(ships_since "$d_from" "$d_end")" = skip ]; then
    say "deploy: skipped, nothing that ships changed since $(printf '%s' "$d_from" | cut -c1-7)"
    return 0
  fi
  say "$gate"
  if [ -f .github/workflows/deploy.yml ] && grep -q '"runner"\|"vercel"' .claude/deploy.json 2>/dev/null; then
    # A project that shows a build id (scripts/ci/build-id.sh) gets it named
    # here, so the line matches what Settings will show.
    d_build=""; if [ -f scripts/ci/build-id.sh ]; then d_build=$(sh scripts/ci/build-id.sh "$d_end" 2>/dev/null | head -n 1); fi
    gh_write api -X POST "repos/{owner}/{repo}/actions/workflows/deploy.yml/dispatches" -f ref="$base" >/dev/null 2>&1 && say "Started the Deploy workflow for what was merged${d_build:+, build $d_build}." || say "$(deploy_refused_message "$base")"
    return 0
  fi
  say "This project deploys from Git (the guard path) or has no Deploy workflow; main deploys on its own."
  start_releases landing
}

