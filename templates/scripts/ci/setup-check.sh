#!/bin/sh
# Fail when a change touches a setup file without a change to SETUP.md.
# The list of setup files is scripts/ci/setup-paths.txt.
# Usage: git diff --name-only BASE HEAD | sh scripts/ci/setup-check.sh
#    or: sh scripts/ci/setup-check.sh BASE HEAD
here=$(dirname "$0")
. "$here/lib.sh"

if [ $# -ge 2 ]; then
  paths=$(git diff --name-only "$1" "$2")
else
  paths=$(cat)
fi

patterns=$(cat "$here/setup-paths.txt")
manual=$(setup_manual "$patterns")
hit=$(setup_check_reason "$paths" "$patterns")
if [ -n "$hit" ]; then
  echo "This change touches $hit, which is a setup step, but $manual did not change; add the line that tells the next person what to run." >&2
  exit 1
fi
echo "Setup check passed."
