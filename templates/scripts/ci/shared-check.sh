#!/bin/sh
# Fail when a change mixes a fix to shared code with other work. The list
# of shared paths is scripts/ci/shared-paths.txt; with an empty list this
# check always passes.
# Usage: git diff --name-only BASE HEAD | sh scripts/ci/shared-check.sh
#    or: sh scripts/ci/shared-check.sh BASE HEAD
here=$(dirname "$0")
. "$here/lib.sh"

if [ $# -ge 2 ]; then
  paths=$(git diff --name-only "$1" "$2")
else
  paths=$(cat)
fi

hit=$(shared_mix_reason "$paths" "$(cat "$here/shared-paths.txt")")
if [ -n "$hit" ]; then
  echo "This change edits shared code ($hit) together with other work. A fix to shared code gets its own issue and its own pull request, so it reaches main on purpose; split it out." >&2
  exit 1
fi
echo "Shared check passed."
