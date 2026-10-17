#!/bin/sh
# Fail when a change touches a source root (src/ by default; one folder per
# line in scripts/ci/spec-roots.txt) without belonging to a spec: the pull
# request names its spec ("Spec: specs/<feature>" in the body, read from
# SPEC_TEXT) or changes a feature folder under specs/. Warn when it touches
# more than one spec folder. The spec is written before building; a pull
# request names it, and touches it only when the design changes.
# Usage: git diff --name-only BASE HEAD | SPEC_TEXT="..." sh scripts/ci/spec-check.sh
#    or: SPEC_TEXT="..." sh scripts/ci/spec-check.sh BASE HEAD
here=$(dirname "$0")
. "$here/lib.sh"

if [ $# -ge 2 ]; then
  paths=$(git diff --name-only "$1" "$2") || { echo "Could not read the diff between $1 and $2; the checkout may be shallow (use fetch-depth: 0). This is not a missing spec." >&2; exit 1; }
else
  paths=$(cat)
fi

roots=$(sed 's/#.*//; /^[[:space:]]*$/d' "$here/spec-roots.txt" 2>/dev/null)
[ -n "$roots" ] || roots="src/"
roots_said=$(printf '%s\n' "$roots" | sed 's/[[:space:]]//g; s#/*$#/#' | paste -sd' ' - | sed 's/ /, /g')
case "$(spec_check_reason "$paths" "${SPEC_TEXT:-}" "$roots")" in
  missing)
    if [ -z "${SPEC_TEXT+x}" ]; then
      echo "The pull request's title and body were not passed to this check (SPEC_TEXT is unset), so a spec named in the body cannot count. Pass them as SPEC_TEXT, as the template workflow does." >&2
    fi
    echo "This change touches source ($roots_said, from scripts/ci/spec-roots.txt) but belongs to no spec. Name it in the pull request body, \"Spec: specs/<feature>\", or, when the design changed, change specs/<feature>/spec.md in the same PR. Do not add a line to a spec just to pass; the constitution does not count." >&2
    exit 1
    ;;
  many*)
    echo "This change touches more than one spec folder; that usually means the task was too big for one PR. Not failing, but consider splitting it."
    ;;
  *)
    echo "Spec check passed."
    ;;
esac
