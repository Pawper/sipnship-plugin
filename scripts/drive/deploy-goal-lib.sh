#!/bin/sh
# The deploy the plan proposes when landed changes are not live. Sourced by
# plan.sh after drive-lib.sh. A landing starts a deploy by itself (the queue,
# and the Deploy workflow when a drain finishes); this is the net under both,
# for a landing neither started, so nothing sits on main unseen.

# deploy_goal BEHIND OLDEST_EPOCH NOW RUNNING [MINUTES]
# The proposal line for a deploy: "deploy (3 landed changes are not live yet,
# the oldest for 42 minutes)". BEHIND is how many landed changes that ship are
# not in production, OLDEST_EPOCH when the oldest of them landed, RUNNING
# "yes" when a deploy is already running or waiting to start. Prints nothing
# when none is behind, one is running, or the oldest landed less than MINUTES
# ago (default 10): a deploy that starts by itself is given its few minutes.
deploy_goal() {
  case "$1" in ''|0|*[!0-9]*) return 0 ;; esac
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  case "$3" in ''|*[!0-9]*) return 0 ;; esac
  [ "$4" != yes ] || return 0
  dg_min=$(( ($3 - $2) / 60 ))
  [ "$dg_min" -ge "${5:-10}" ] || return 0
  if [ "$1" = 1 ]; then dg_w="landed change is"; else dg_w="landed changes are"; fi
  printf 'deploy (%s %s not live yet, the oldest for %s minutes)\n' "$1" "$dg_w" "$dg_min"
}

# deploy_proposal
# The one line the plan adds for a deploy, or nothing: read from the
# project's own deploy settings (.claude/deploy.json) and its deploy helpers.
# A project with no deploy path, no gh, or no commit recorded in production
# proposes nothing; the session brief and the nightly audit say those.
deploy_proposal() {
  [ -f .claude/deploy.json ] && [ -f scripts/ci/deploy-lib.sh ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  dp_line=$(
    . scripts/ci/deploy-lib.sh
    cfg=$(cat .claude/deploy.json)
    case "$(json_string "$cfg" path)" in runner|vercel) ;; *) exit 0 ;; esac
    app=$(json_string "$cfg" appRoot); [ -n "$app" ] || app=.
    extra=$(json_words "$cfg" neverShips); also=$(json_words "$cfg" alsoShips)
    main=$(release_ref)
    main=$(git rev-parse -q --verify "$main" 2>/dev/null) || exit 0
    if command -v timeout >/dev/null 2>&1; then deployed=$(timeout 20 git ls-remote origin refs/deploy/production 2>/dev/null | cut -f1)
    else deployed=$(git ls-remote origin refs/deploy/production 2>/dev/null | cut -f1); fi
    [ -n "$deployed" ] && [ "$deployed" != "$main" ] && git cat-file -e "$deployed^{commit}" 2>/dev/null || exit 0
    behind=0; oldest=""
    for c in $(git rev-list --reverse "$deployed..$main" 2>/dev/null); do
      if [ "$(deploy_skip "$(git diff-tree --no-commit-id --name-only -r -m "$c" 2>/dev/null)" "$app" "$extra" "$also")" = build ]; then
        behind=$((behind + 1)); [ -n "$oldest" ] || oldest=$(git log -1 --format=%ct "$c")
      fi
    done
    running=$(gh api 'repos/{owner}/{repo}/actions/workflows/deploy.yml/runs?per_page=10' \
      --jq '[.workflow_runs[] | select(.status != "completed")] | length' 2>/dev/null | tr -d '\r')
    case "$running" in ''|0|*[!0-9]*) running=no ;; *) running=yes ;; esac
    deploy_goal "$behind" "$oldest" "$(date +%s)" "$running"
  )
  [ -z "$dp_line" ] || printf '%s\n' "$dp_line"
}

# add_deploy ROUND LINE
# Put deploy_proposal's line into a round as a goal, as add_goal does; a round
# without a line comes back as it was.
add_deploy() {
  case "$2" in
    '') printf '%s\n' "$1" ;;
    *) add_goal "$1" "$2" ;;
  esac
}
