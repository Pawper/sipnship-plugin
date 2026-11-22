#!/bin/sh
# Free the fixes a fix agent could not push (#2260), by script, with no model. A fix agent whose push to the change's branch
# was refused leaves its commit on a side branch (fixside/pr-N) and a comment "Fix waits: #M | side: BRANCH". For each side
# branch on the remote:
#   - the change merged or closed: the side branch is removed;
#   - what it waits on has landed (or the note names nothing): the side branch is merged into the change's branch and
#     pushed, server side over REST, and the side branch is removed; when that cannot be done a fix agent is owed again,
#     a comment says so once, and the red change is owed a fix agent as any is (fix-owed.sh), starting from the side branch;
#   - otherwise it waits.
# Prints one plain line for each it acts on. Without --apply it only says.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/fix-side.sh" [--apply]
here=$(dirname "$0")
. "$here/fix-side-lib.sh"
apply=no; [ "${1:-}" = --apply ] && apply=yes
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || exit 0
refs=$(gh api "repos/{owner}/{repo}/git/matching-refs/heads/fixside/" --jq '.[].ref' 2>/dev/null | tr -d '\r' | sed 's#^refs/heads/##')
for side in $refs; do
  pr=${side#fixside/pr-}
  case "$pr" in ""|*[!0-9]*) continue ;; esac
  info=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '[.state, (.merged_at != null | tostring), .head.ref] | @tsv' 2>/dev/null | tr -d '\r')
  [ -n "$info" ] || { echo "fix-side: could not read pull request #$pr; $side is left as it is."; continue; }
  state=$(printf '%s' "$info" | cut -f1); merged=$(printf '%s' "$info" | cut -f2); head=$(printf '%s' "$info" | cut -f3)
  [ "$merged" = true ] && state=merged
  comments=$(gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --jq '.[].body' 2>/dev/null)
  waits=$(fix_side_waits "$comments")
  wstate=none
  if [ -n "$waits" ]; then
    wstate=$(gh api "repos/{owner}/{repo}/issues/$waits" --jq 'if .pull_request.merged_at != null then "merged" else .state end' 2>/dev/null | tr -d '\r'); [ -n "$wstate" ] || wstate=open
  fi
  case "$(fix_side_action "$state" "$wstate")" in
    remove)
      echo "fix-side: pull request #$pr has ended, so its side branch $side is removed."
      [ "$apply" = yes ] && gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$side" >/dev/null 2>&1 ;;
    merge)
      echo "fix-side: ${waits:+#$waits has landed, so }the fix on $side is merged into $head for pull request #$pr."
      [ "$apply" = yes ] || continue
      if [ "$(fix_side_failed "$comments")" = yes ]; then continue; fi  # tried once already: the fix agent is owed, starting from the side branch
      if gh api -X POST "repos/{owner}/{repo}/merges" -f base="$head" -f head="$side" -f commit_message="Merge the fix from $side" >/dev/null 2>&1; then
        gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$side" >/dev/null 2>&1
      else
        echo "fix-side: the fix on $side could not be merged into $head; a fix agent is owed for pull request #$pr, starting from the side branch."
        gh api -X POST "repos/{owner}/{repo}/issues/$pr/comments" -f body="$(fix_side_failed_note "$side")" >/dev/null 2>&1
      fi ;;
    *) echo "fix-side: the fix on $side waits for #$waits to land." ;;
  esac
done
exit 0
