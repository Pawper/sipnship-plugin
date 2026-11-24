#!/bin/sh
# One named step of a test part that holds several checks: prints the step's
# name above its output, runs it, and on a red names it in an annotation, so
# a failure in the middle of a grouped part still names the check that broke.
#   sh scripts/ci/part-step.sh NAME COMMAND [ARGS...]
name=$1; shift
echo "=== $name: $*"
"$@"
code=$?
if [ "$code" -ne 0 ]; then
  echo "=== $name failed (exit $code)"
  echo "::error title=$name failed::The $name check failed; its output is above."
fi
exit "$code"
