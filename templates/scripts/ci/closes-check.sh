#!/bin/sh
# Fail when a pull request does not close an issue, or names a leftover that
# is not an open issue. One change closes its issue; anything it leaves
# undone becomes a new issue filed before the change lands, named on a line
# of the body, written exactly: "Leftover: #M". Open then always means not
# started or being worked; closed always means landed.
# Usage: PR_BODY="..." sh scripts/ci/closes-check.sh
#   ISSUE_STATE_CMD (tests) names a command that prints an issue's state
#   (open, closed or nothing) for the number it is given.
rules_lib="$(dirname "$0")/rules-lib.sh"
if [ -f "$rules_lib" ]; then . "$rules_lib"; if rule_skip one-change-closes-its-issue; then exit 0; fi; fi
body=$(printf '%s\n' "${PR_BODY:-}" | tr -d '\r')

issue_state() {
  if [ -n "${ISSUE_STATE_CMD:-}" ]; then $ISSUE_STATE_CMD "$1"; return; fi
  gh api "repos/${GITHUB_REPOSITORY:-{owner\}/{repo\}}/issues/$1" --jq .state 2>/dev/null
}

fail=0
if ! printf '%s\n' "$body" | grep -Eiq '^[[:space:]]*(closes|fixes|resolves) +#[0-9]+'; then
  echo "This pull request closes no issue. One change closes its issue: add a line to the body, written exactly so: Closes #N. If it does only part of what the issue asked, file a new issue for what is left, then add the line Leftover: #M. A body that says Part of or Refs and leaves its issue open is not allowed." >&2
  fail=1
fi

for n in $(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*Leftover: *#\([0-9][0-9]*\).*/\1/p'); do
  state=$(issue_state "$n")
  if [ "$state" != open ]; then
    echo "Leftover: #$n is not an open issue (${state:-not found}). File the issue for what this change leaves undone before the pull request lands, then name it on the line Leftover: #M." >&2
    fail=1
  fi
done

[ "$fail" = 0 ] && echo "Closes check passed."
exit "$fail"
