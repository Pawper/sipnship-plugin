#!/bin/sh
# The test parts of classes.txt's "!parts" lines, for CI.
#   sh scripts/ci/test-parts.sh matrix "CLASSES"  the JSON list of part
#       names a change of CLASSES runs ([] when none): the pull request's
#       test matrix, one entry per part
#   sh scripts/ci/test-parts.sh run NAME          run one part's command
#   sh scripts/ci/test-parts.sh all               every part of every class,
#       one after another, to the end (main's full run); CI_FULL_RUN=yes is
#       set so a runner that stops at its first red runs everything
here=$(dirname "$0")
. "$here/lib.sh"
rules=$(cat "$here/classes.txt")
case "$1" in
  matrix) parts_matrix "$(class_parts "$2" "$rules")" ;;
  run)
    cmd=$(class_parts all "$rules" | awk -F '\t' -v n="$2" '$1 == n { print $2; exit }')
    [ -n "$cmd" ] || { echo "no test part named $2 in scripts/ci/classes.txt" >&2; exit 2; }
    echo "Part $2: $cmd"
    sh -c "$cmd" ;;
  all)
    export CI_FULL_RUN=yes
    failed=
    parts=$(class_parts all "$rules")
    [ -n "$parts" ] || { echo "No test parts in scripts/ci/classes.txt."; exit 0; }
    while IFS="	" read -r name cmd; do
      echo "Part $name: $cmd"
      sh -c "$cmd" </dev/null || failed="$failed $name"
    done <<PARTS
$parts
PARTS
    [ -z "$failed" ] || { echo "Parts that failed:$failed" >&2; exit 1; }
    echo "Every part passed." ;;
  *) echo "usage: test-parts.sh matrix CLASSES | run NAME | all" >&2; exit 2 ;;
esac
