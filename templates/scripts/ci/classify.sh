#!/bin/sh
# Print the change classes for a set of paths, space separated.
# Usage: git diff --name-only BASE HEAD | sh scripts/ci/classify.sh
#    or: sh scripts/ci/classify.sh BASE HEAD
here=$(dirname "$0")
. "$here/lib.sh"

if [ $# -ge 2 ]; then
  paths=$(git diff --name-only "$1" "$2")
else
  paths=$(cat)
fi
classify_paths "$paths" "$(cat "$here/classes.txt")"
echo
