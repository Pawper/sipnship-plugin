#!/bin/sh
# The mock check: a pull request that changes a UI file mapped in
# scripts/ci/mocks.txt changes its mock too (either file of a light and
# dark pair, or its generator), or says why not in its body, written
# exactly so: "Mock: unchanged, <reason>" (read from SPEC_TEXT or PR_TEXT).
# A new UI file in a mapped folder that no line names fails until a line
# maps it or an "unmocked PATH" line declares it.
# Usage: SPEC_TEXT="..." sh scripts/ci/mock-check.sh BASE HEAD
#    or: sh scripts/ci/mock-check.sh --stale   (screens whose mock is older
#        than their UI by more than stale-after commits; the brief reads it)
here=$(dirname "$0")
. "$here/mock-lib.sh"
cfg=scripts/ci/mocks.txt
[ -f "$cfg" ] || { echo "No scripts/ci/mocks.txt; nothing to check."; exit 0; }
text=$(cat "$cfg")

if [ "${1:-}" = "--stale" ]; then
  counts=$(mock_lines "$text" | while IFS='	' read -r n ui mocks; do
    set -f
    # shellcheck disable=SC2086
    last=$(git log -1 --format=%H -- $mocks 2>/dev/null)
    if [ -n "$last" ]; then
      # shellcheck disable=SC2086
      c=$(git rev-list --count "$last..HEAD" -- $ui 2>/dev/null)
    else
      # shellcheck disable=SC2086
      c=$(git rev-list --count HEAD -- $ui 2>/dev/null)
    fi
    set +f
    printf '%s\t%s\n' "$n" "${c:-0}"
  done)
  stale_mocks "$counts" "$(mock_stale_after "$text")"
  exit 0
fi

base=${1:?usage: mock-check.sh BASE HEAD}; head=${2:?usage: mock-check.sh BASE HEAD}
# Judged on the pull request's own lines, as the design check is.
if git rev-parse -q --verify "$head^2" >/dev/null 2>&1; then
  base=$(git rev-parse "$head^1")
else
  mb=$(git merge-base "$base" "$head" 2>/dev/null) && base=$mb
fi
changed=$(git diff --name-only "$base" "$head") || { echo "Could not read the diff between $base and $head; the checkout may be shallow (use fetch-depth: 0). This is not a stale mock." >&2; exit 1; }
added=$(git diff --name-only --diff-filter=AM "$base" "$head")

fail=0
missing=$(mock_missing "$changed" "$text")
if [ -n "$missing" ]; then
  why=$(mock_escape "${SPEC_TEXT:-${PR_TEXT:-}}")
  if [ -n "$why" ]; then
    echo "Screens changed without their mock, allowed by the pull request: Mock: unchanged, $why"
    printf '%s\n' "$missing" | sed 's/^/  /'
  else
    echo "These screens changed but their mocks did not: $(printf '%s' "$missing" | paste -sd' ' - | sed 's/ /, /g'). Change the mock, or regenerate it, in the same pull request; or, when the picture still holds, add a line to the body, written exactly so: Mock: unchanged, <reason>" >&2
    fail=1
  fi
fi
unmapped=$(mock_unmapped "$added" "$text")
if [ -n "$unmapped" ]; then
  echo "These UI files sit beside mocked screens, but no line in scripts/ci/mocks.txt names them: $(printf '%s' "$unmapped" | paste -sd' ' - | sed 's/ /, /g'). Map each to its mock (NAME UI_PATH MOCK_PATH), or declare it with a line: unmocked PATH" >&2
  fail=1
fi
[ "$fail" -ne 0 ] || echo "Mock check passed."
exit "$fail"
