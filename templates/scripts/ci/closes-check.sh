#!/bin/sh
# Fail when a pull request does not close an issue, names a leftover that is
# not an open issue, names a leftover whose own body repeats the closed
# issue's title or "What done looks like" lines, or names a leftover that is
# itself already a leftover of something else. One change closes its issue;
# anything it leaves undone becomes a new issue filed before the change
# lands, named on a line of the body, written exactly: "Leftover: #M". Open
# then always means not started or being worked; closed always means
# landed. A change may close an issue only when it builds what the issue's
# "What done looks like" asks: naming the same ask again as a leftover is
# not building less of it, it is building none of it (#2399). A leftover
# whose own body already carries a "Leftover:" line is not the original ask
# either; filing a further leftover of it only compounds the chain without
# building anything, so the fix is to reopen what it traces back to, or keep
# building it directly, never a third issue asking the same thing again.
# Usage: PR_BODY="..." sh scripts/ci/closes-check.sh
#   ISSUE_STATE_CMD (tests) names a command that prints an issue's state
#   (open, closed, unverified or nothing) for the number it is given.
#   ISSUE_TITLE_CMD (tests) names a command that prints an issue's title for
#   the number it is given.
#   ISSUE_BODY_CMD (tests) names a command that prints an issue's body for
#   the number it is given.
rules_lib="$(dirname "$0")/rules-lib.sh"
if [ -f "$rules_lib" ]; then . "$rules_lib"; if rule_skip one-change-closes-its-issue; then exit 0; fi; fi
body=$(printf '%s\n' "${PR_BODY:-}" | tr -d '\r')

no_credential() { [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; }
issue_state() {
  if [ -n "${ISSUE_STATE_CMD:-}" ]; then $ISSUE_STATE_CMD "$1"; return; fi
  # No credential (the local pre-push run unsets it on purpose): cannot verify.
  no_credential && { echo unverified; return; }
  gh api "repos/${GITHUB_REPOSITORY:-{owner\}/{repo\}}/issues/$1" --jq .state 2>/dev/null
}
issue_title() {
  if [ -n "${ISSUE_TITLE_CMD:-}" ]; then $ISSUE_TITLE_CMD "$1"; return; fi
  no_credential && return
  gh api "repos/${GITHUB_REPOSITORY:-{owner\}/{repo\}}/issues/$1" --jq .title 2>/dev/null
}
issue_body() {
  if [ -n "${ISSUE_BODY_CMD:-}" ]; then $ISSUE_BODY_CMD "$1"; return; fi
  no_credential && return
  gh api "repos/${GITHUB_REPOSITORY:-{owner\}/{repo\}}/issues/$1" --jq .body 2>/dev/null
}
# The lines of a "What done looks like" (or "What done would look like") section, trimmed to its
# own heading's bounds, so two issues asking the same thing word for word are told apart from two
# that merely share a heading.
what_done_lines() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^#+[ \t]*What done/ { grab = 1; next }
    grab && /^#+[ \t]/ { grab = 0 }
    grab { print }'
}

fail=0
closes_list=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*\(closes\|fixes\|resolves\)[[:space:]]\+#\([0-9][0-9]*\).*/\2/Ip')
if [ -z "$closes_list" ]; then
  echo "This pull request closes no issue. One change closes its issue: add a line to the body, written exactly so: Closes #N. If it does only part of what the issue asked, file a new issue for what is left, then add the line Leftover: #M. A body that says Part of or Refs and leaves its issue open is not allowed." >&2
  fail=1
fi

for n in $(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*Leftover: *#\([0-9][0-9]*\).*/\1/p'); do
  state=$(issue_state "$n")
  if [ "$state" = unverified ]; then
    echo "Leftover: #$n not checked here (no credential for a network call); CI checks it on the pull request."
    continue
  elif [ "$state" != open ]; then
    echo "Leftover: #$n is not an open issue (${state:-not found}). File the issue for what this change leaves undone before the pull request lands, then name it on the line Leftover: #M." >&2
    fail=1
    continue
  fi
  mbody=$(issue_body "$n")
  lchain=$(printf '%s\n' "$mbody" | sed -n 's/^[[:space:]]*Leftover: *#\([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -n "$lchain" ]; then
    echo "Leftover: #$n is itself a leftover (its own body names Leftover: #$lchain), so it is not the original ask. Reopen the issue it traces back to, or keep building #$n directly; a leftover of a leftover compounds the chain without building anything." >&2
    fail=1
    continue
  fi
  mtitle=$(issue_title "$n")
  msection=$(what_done_lines "$mbody")
  for c in $closes_list; do
    ctitle=$(issue_title "$c")
    if [ -n "$mtitle" ] && [ -n "$ctitle" ] && [ "$mtitle" = "$ctitle" ]; then
      echo "Leftover: #$n repeats the exact title of #$c, which this pull request closes. A change may close an issue only when it builds what the issue's \"What done looks like\" asks; the real ask stays undone until it is built. Build it, or leave #$c open instead of filing the same ask again." >&2
      fail=1
      continue
    fi
    csection=$(what_done_lines "$(issue_body "$c")")
    if [ -n "$msection" ] && [ -n "$csection" ] && [ "$msection" = "$csection" ]; then
      echo "Leftover: #$n repeats #$c's own \"What done looks like\" lines word for word. A change may close an issue only when it builds what those lines ask; build the real ask, or leave #$c open instead of filing the same ask again." >&2
      fail=1
    fi
  done
done

# A line of a "What done looks like" section, with its own "- " bullet marker dropped, one per line (#2453).
what_done_bullets() {
  printf '%s\n' "$(what_done_lines "$1")" | sed -n 's/^[[:space:]]*-[[:space:]]\+//p'
}

# A pull request that builds part of an issue without closing it names which line, word for word:
# "Built #N: <the line>" (also read the same way from a later comment, by the service). A line with
# no text, or one that matches none of #N's own lines once #N is readable, fails (#2453, D7).
built_tab=$(printf '\t')
built_out=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*Built #\([0-9][0-9]*\):[[:space:]]*\(.*\)$/\1'"$built_tab"'\2/p' | while IFS="$built_tab" read -r n text; do
  [ -n "$n" ] || continue
  if [ -z "$text" ]; then
    echo "FAIL:Built #$n: names no line; say exactly which line of its \"What done looks like\" this change built, word for word."
    continue
  fi
  bstate=$(issue_state "$n")
  if [ "$bstate" = unverified ]; then
    echo "Built #$n not checked here (no credential for a network call); CI checks it on the pull request."
    continue
  fi
  if ! what_done_bullets "$(issue_body "$n")" | grep -qxF "$text"; then
    echo "FAIL:Built #$n: \"$text\" matches none of #$n's own \"What done looks like\" lines; quote the line word for word."
  fi
done)
if [ -n "$built_out" ]; then
  printf '%s\n' "$built_out" | sed 's/^FAIL://' >&2
  printf '%s\n' "$built_out" | grep -q '^FAIL:' && fail=1
fi

[ "$fail" = 0 ] && echo "Closes check passed."
exit "$fail"
