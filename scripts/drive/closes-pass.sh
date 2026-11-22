#!/bin/sh
# One pass over the open pull requests the closes check would fail (#2269): a change opened before the rule says "Part of"
# and no "Closes", and fails the moment the owner approves it. For each, the pass says what it would do; with --apply it
# does it, over REST, with no model:
#   - a change that is only a spec and mocks (every file under specs/ or design/) gets a small issue, "The spec and mocks of
#     X", filed In progress, and a Closes line naming it; the build's issue stays open and is named in plain words;
#   - any other change that names an issue it is part of is listed for a person: the pass never closes a build's issue by
#     guessing that this change finished it.
# Safe to run again: a body that already closes an issue is skipped.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/closes-pass.sh" [--apply]
here=$(dirname "$0")
. "$here/closes-lib.sh"
apply=no; [ "${1:-}" = --apply ] && apply=yes
command -v gh >/dev/null 2>&1 || { echo "gh is not available; the pass has nothing to read."; exit 0; }
scratch=${CLOSES_PASS_SCRATCH:-.scratch/closes-pass}; mkdir -p "$scratch"
tab=$(printf '\t')
list=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [(.number | tostring), .head.ref, ((.body // "") | [scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0]] | join(","))] | @tsv' 2>/dev/null | tr -d '\r')
missing=$(closes_missing "$list")
[ -n "$missing" ] || { echo "closes: every open pull request names an issue it closes."; exit 0; }
for n in $missing; do
  body=$(gh api "repos/{owner}/{repo}/pulls/$n" --jq '.body // ""' 2>/dev/null | tr -d '\r')
  title=$(gh api "repos/{owner}/{repo}/pulls/$n" --jq '.title' 2>/dev/null | tr -d '\r')
  [ "$(closes_has_line "$body")" = no ] || continue
  candidates=$(closes_part_of_all "$body")
  states=""
  for c in $candidates; do
    cs=$(gh api "repos/{owner}/{repo}/issues/$c" --jq .state 2>/dev/null)
    [ -n "$cs" ] && states="${states}${c}${tab}${cs}
"
  done
  # A change part of more than one build (several "Part of" lines) names the one still open, never one already
  # done, so the new issue's own title does not quote a build that finished (#2324).
  build=$(closes_pick_open_build "$candidates" "$states")
  files=$(gh api "repos/{owner}/{repo}/pulls/$n/files?per_page=100" --jq '.[].filename' 2>/dev/null | tr -d '\r')
  if [ "$(closes_spec_only "$files")" != yes ]; then
    echo "closes: pull request #$n “$title” changes more than a spec and mocks${build:+, and says it is part of #$build}; a person says which issue it closes."
    continue
  fi
  btitle=""; [ -n "$build" ] && btitle=$(gh api "repos/{owner}/{repo}/issues/$build" --jq '.title' 2>/dev/null | tr -d '\r')
  newtitle=$(closes_spec_title "${btitle:-$title}")
  if [ "$apply" != yes ]; then
    echo "closes: pull request #$n “$title” would get a small issue, “$newtitle”, and a Closes line${build:+; the build (#$build) stays open}."
    continue
  fi
  printf 'The spec and mocks drawn in pull request #%s, filed so the change has an issue to close.\n' "$n" > "$scratch/issue-$n.md"
  filed=$(ISSUE_OPEN_CLAIM="pull-request-$n" sh scripts/issue-open.sh "$newtitle" "$scratch/issue-$n.md" state:in-progress 2>&1) || { echo "closes: could not file the issue for pull request #$n: $filed"; continue; }
  num=$(printf '%s' "$filed" | sed -n 's/^Filed issue #\([0-9][0-9]*\).*/\1/p')
  [ -n "$num" ] || { echo "closes: could not read the new issue's number for pull request #$n"; continue; }
  closes_add_line "$body" "$num" "$build" "$btitle" > "$scratch/body-$n.md"
  gh api -X PATCH "repos/{owner}/{repo}/pulls/$n" -F body=@"$scratch/body-$n.md" >/dev/null 2>&1 \
    && echo "closes: pull request #$n now closes issue #$num${build:+; the build (#$build) stays open}." \
    || echo "closes: filed issue #$num but could not change pull request #$n's body; add the line Closes #$num by hand."
done
exit 0
