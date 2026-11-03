#!/bin/sh
# The session brief's slow lines, read in the background so the start hook
# never waits on them. session-brief.sh starts this, detached, from the
# project root when the cache is older than five minutes; the next start
# reads what it wrote and says how old it is.
#
# Usage: sh session-brief-slow.sh CACHE_DIR
#
# Each line is its own file in CACHE_DIR, replaced whole when its step ends:
#   deploy-health    scripts/ci/deploy-health.sh's line
#   workflow-breaks  scripts/ci/workflow-breaks.sh's first four, joined
#   live-app         the live app's one line, from the latest Live run
#   mock-stale       mock-check.sh --stale's first six, joined
#   hotspots         the hotspot line
#   plan             the drive's plan, from CACHE_DIR/facts.tsv (the board
#                    the hook read)
#   stamp            when the last read ended, epoch seconds
# The steps run side by side, each bounded; one read at a time, held by the
# CACHE_DIR/lock folder. Fails soft: a step that fails or runs out of time
# leaves its file empty, and the brief says nothing for it.
here=$(dirname "$0")
cache=$1
[ -n "$cache" ] || exit 0
mkdir -p "$cache" 2>/dev/null || exit 0

# One read at a time. A lock older than five minutes is a read that died.
if ! mkdir "$cache/lock" 2>/dev/null; then
  lk_m=$(stat -c %Y "$cache/lock" 2>/dev/null || stat -f %m "$cache/lock" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - lk_m )) -gt 300 ] || exit 0
  rmdir "$cache/lock" 2>/dev/null
  mkdir "$cache/lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$cache/lock" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP

bound=${SIPNSHIP_BRIEF_SLOW_BOUND:-90}
run_bounded() {
  rb_s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$rb_s" "$@"; else "$@"; fi
}
# keep NAME: stdin becomes CACHE_DIR/NAME, replaced whole.
keep() { cat > "$cache/$1.new" && mv -f "$cache/$1.new" "$cache/$1"; }
joined() { head -n "$1" | paste -sd';' - | sed 's/;/; /g'; }

have_git=no
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then have_git=yes; fi
have_gh=no
command -v gh >/dev/null 2>&1 && have_gh=yes

# Deploys, when the project's deploy path is not keeping up.
if [ -f .claude/deploy.json ] && [ -f scripts/ci/deploy-health.sh ]; then
  (run_bounded "$bound" sh scripts/ci/deploy-health.sh 2>/dev/null | keep deploy-health) &
fi

# A workflow that passed before its last change on main and has failed
# every run since, which a template sync can cause.
if [ -f scripts/ci/workflow-breaks.sh ] && [ "$have_git" = yes ] && [ "$have_gh" = yes ]; then
  (run_bounded "$bound" sh scripts/ci/workflow-breaks.sh 2>/dev/null | joined 4 | keep workflow-breaks) &
fi

# Whether the live app works, from the latest Live run that looked at it.
if [ -f .github/workflows/live.yml ] && [ "$have_gh" = yes ]; then
  (run_bounded "$bound" sh "$here/session-brief-live.sh" 2>/dev/null | head -n 1 | keep live-app) &
fi

# Screens whose mock has fallen behind their UI by more than the
# stale-after commits in scripts/ci/mocks.txt (20 by default). Local git only.
if [ -f scripts/ci/mocks.txt ] && [ "$have_git" = yes ] && [ -f "$here/../../templates/scripts/ci/mock-check.sh" ]; then
  (run_bounded "$bound" sh "$here/../../templates/scripts/ci/mock-check.sh" --stale 2>/dev/null | joined 6 | keep mock-stale) &
fi

# The files over their size limit, the files several open pull requests
# edit, and the CI jobs over their time limit.
if [ -f scripts/ci/hotspots.txt ] && [ -f scripts/ci/hotspots-lib.sh ] && [ "$have_git" = yes ]; then
  (
    has() { return 0; }
    add() { printf '%s\n' "$1"; }
    facts=$(cat "$cache/facts.tsv" 2>/dev/null)
    ml_file="${SIPNSHIP_HOME:-$HOME/.sipnship}/runner-watch/machine.tsv"
    . "$here/session-brief-hotspots.sh"
  ) 2>/dev/null | keep hotspots &
fi

# The drive's proposal, from the board the hook read. Read-only. With no
# board read (gh signed out), an empty plan: the brief says unavailable.
if [ -f .claude/project-drive.json ] && [ -f "$here/../../scripts/drive/plan.sh" ]; then
  if [ -s "$cache/facts.tsv" ]; then
    (run_bounded "$bound" sh "$here/../../scripts/drive/plan.sh" --fast --facts "$cache/facts.tsv" 2>/dev/null | keep plan) &
  else
    : | keep plan
  fi
fi

wait
date +%s > "$cache/stamp.new" && mv -f "$cache/stamp.new" "$cache/stamp"
exit 0
