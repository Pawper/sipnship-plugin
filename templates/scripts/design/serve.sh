#!/bin/sh
# Start and stop the built app for the screens job, which renders each
# touched screen beside its mock (scripts/design/screens-diff.mjs).
#   sh scripts/design/serve.sh start   start the app in the background with
#                                      the fixture data and print its base
#                                      URL, for example http://127.0.0.1:4173,
#                                      as the first line; return once it answers
#   sh scripts/design/serve.sh stop    stop what start started
# FIXTURES is the path from the "# fixtures: PATH" line in
# scripts/ci/mocks.txt, the one file of sample data the mocks read too;
# load it, so both sides show the same names and numbers.
# The job always calls stop, even after a failure: a server left running
# holds the runner's port and the next job's worktree.
# This file is a stub until the line below is gone; the job skips while it
# is there. Fill in both cases, then remove the line.
# screens: stub
set -e
case "${1:-}" in
  start)
    # For example, a static build served by a script of the app's own:
    #   (cd web && npm run build >/dev/null && FIXTURES="$FIXTURES" nohup npm run preview -- --port 4173 >../.scratch/serve.log 2>&1 & echo $! >../.scratch/serve.pid)
    #   for i in $(seq 1 30); do curl -fs http://127.0.0.1:4173/ >/dev/null && break; sleep 1; done
    #   echo http://127.0.0.1:4173
    echo "scripts/design/serve.sh is not filled in yet." >&2; exit 1 ;;
  stop)
    #   [ -f .scratch/serve.pid ] && kill "$(cat .scratch/serve.pid)" 2>/dev/null || true
    exit 0 ;;
  *) echo "Usage: sh scripts/design/serve.sh start | stop" >&2; exit 2 ;;
esac
