#!/bin/sh
# The test parts of classes.txt's "!parts" lines, for CI.
#   sh scripts/ci/test-parts.sh matrix "CLASSES"  the JSON list of part
#       names a change of CLASSES runs ([] when none): the pull request's
#       test matrix, one entry per part
#   sh scripts/ci/test-parts.sh skipped "CLASSES"  the parts that change leaves
#       out, one line each with the reason (the checks list prints it)
#   sh scripts/ci/test-parts.sh run NAME         run one part's command
#   sh scripts/ci/test-parts.sh all               every part of every class,
#       one after another, to the end (main's full run); CI_FULL_RUN=yes is
#       set so a runner that stops at its first red runs everything
here=$(dirname "$0")
. "$here/lib.sh"
rules=$(cat "$here/classes.txt")
case "$1" in
  matrix) parts_matrix "$(class_parts "$2" "$rules")" ;;
  skipped)
    # The parts a change of CLASSES leaves out, and why, one plain line each:
    # "shell-1-2: skipped, nothing changed in plugin, ci or scripts".
    ran=$(parts_matrix "$(class_parts "$2" "$rules")")
    class_parts all "$rules" | cut -f1 | while read -r sp_name; do
      case "$ran" in *"\"$sp_name\""*) continue ;; esac
      sp_why=$(printf '%s\n' "$rules" | tr -d '\r' | awk -v n="$sp_name" '
        { sub(/#.*/, "") } $1 != "!parts" { next }
        { rest = $0; sub(/^[ \t]*!parts[ \t]+[^ \t]+[ \t]*/, "", rest); m = split(rest, ps, ";")
          for (i = 1; i <= m; i++) { p = ps[i]; gsub(/^[ \t]+/, "", p); if (index(p, n "=") == 1) { c = $2; gsub(/,/, ", ", c); print c; exit } } }')
      echo "$sp_name: skipped, nothing changed in $sp_why"
    done ;;
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
  *) echo "usage: test-parts.sh matrix CLASSES | skipped CLASSES | run NAME | all" >&2; exit 2 ;;
esac
