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
. "$here/failure-lib.sh"
rules=$(cat "$here/classes.txt")
# machine_probe: how long 40 starts of sh and 40 starts of git take, in milliseconds each; "unknown" when it cannot be timed.
machine_probe() {
  mp_t0=$(date +%s%N 2>/dev/null); case "$mp_t0" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  mp_i=0; while [ "$mp_i" -lt 40 ]; do sh -c ':'; mp_i=$((mp_i + 1)); done
  mp_t1=$(date +%s%N); mp_i=0
  while [ "$mp_i" -lt 40 ]; do git --version >/dev/null 2>&1; mp_i=$((mp_i + 1)); done
  mp_t2=$(date +%s%N)
  echo "a start of sh takes $(( (mp_t1 - mp_t0) / 40000000 )) ms and a start of git $(( (mp_t2 - mp_t1) / 40000000 )) ms"
}
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
    # A fixed small probe, so a slow machine is told from a slow test (time is never gated): 40 starts of sh and of git.
    echo "Machine probe: $(machine_probe)"
    # A part that ends failed says why in one line, so one with no failing test is never a mystery.
    sh -c "$cmd"; rc=$?
    [ "$rc" -eq 0 ] || echo "Part $2 ended with exit code $rc: $(exit_words "$rc")."
    exit "$rc" ;;
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
