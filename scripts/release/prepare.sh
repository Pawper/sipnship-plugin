#!/bin/sh
# Prepare the plugin release by script the moment plugin changes sit on main
# with no release open: file the issue, bump the version in its own worktree,
# push the branch and open the pull request. No person and no model: the
# drive's wake check runs this before the plan, so a release stops waiting
# for a proposal to be read and approved. Never merges (the queue does) and
# never tags. Prints one line and exits 0 whatever happens:
#   release: nothing to release
#   release: 0.43.55 is already open (#2150)
#   release: opened pull request #2151 for 0.43.55 (issue #2150)
#   release: could not prepare 0.43.55 (why)
#
#   sh plugin/scripts/release/prepare.sh [--dry-run]
#
# Run from the project root. The number is the one past the newer of main's
# version and the newest published tag, as the plan proposes it. Stand-ins
# for the suite: PREPARE_ISSUES and PREPARE_PULLS name files of "NUMBER<TAB>
# TITLE" lines instead of asking GitHub; ISSUE_OPEN and PR_OPEN name other
# scripts; PREPARE_WORKTREES names the folder the worktree goes in.
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../.." && pwd)
dry=no; [ "$1" = --dry-run ] && dry=yes
. "$plugin/hooks/scripts/lib.sh"
. "$plugin/hooks/scripts/session-brief-versions.sh"
[ -f "$plugin/templates/scripts/ci/git-bounded-lib.sh" ] && . "$plugin/templates/scripts/ci/git-bounded-lib.sh"
. "$plugin/scripts/drive/drive-lib.sh"
. "$plugin/scripts/drive/release-lib.sh"
say() { echo "release: $*"; exit 0; }

ref=$(release_ref)
cur=$(newer_plugin_version "$(plugin_version_at "$ref")" "$(published_plugin_version)")
count=$(plugin_unreleased_count "$ref")
next=$(next_patch "$cur")
case "$count" in ''|0|*[!0-9]*) say "nothing to release" ;; esac
[ -n "$next" ] || say "nothing to release (no version to count from)"

# One REST call each for the open issues and pull requests; any whose title names the number and says plugin or release is the release.
if [ -n "${PREPARE_ISSUES:-}" ]; then items=$(cat "$PREPARE_ISSUES" "${PREPARE_PULLS:-/dev/null}" 2>/dev/null)
else
  items=$(gh api "repos/{owner}/{repo}/issues?state=open&per_page=100" --jq '.[] | [.number, .title] | @tsv' 2>/dev/null | tr -d '\r')
fi
open=$(printf '%s\n' "$items" | awk -F'\t' -v v="$next" '
  { s = $2; i = index(s, v); if (!i) next
    c = substr(s, i + length(v), 1)
    if (c ~ /[0-9]/ || (c == "." && substr(s, i + length(v) + 1, 1) ~ /[0-9]/)) next
    if (tolower(s) !~ /(plugin|release)/) next
    print $1; exit }')
[ -z "$open" ] || say "$next is already open (#$open)"
branch="release-$(printf '%s' "$next" | tr . -)"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then say "$next is already open (branch $branch)"; fi
[ "$dry" = no ] || say "would prepare $next ($count plugin changes unreleased)"

fail() { say "could not prepare $next ($1)"; }
mkdir -p .scratch
cat > .scratch/release-issue.md <<EOF
Release the plugin as $next: $count plugin changes sit on main with no release open. Prepared by the drive's wake check: the version bump and the pull request come with this issue.

Spec: specs/constitution.md
EOF
out=$(sh "${ISSUE_OPEN:-scripts/issue-open.sh}" "Release the plugin as $next" .scratch/release-issue.md state:ready 2>&1) || fail "the issue could not be filed: $(printf '%s' "$out" | tail -n 1)"
issue=$(printf '%s\n' "$out" | sed -n 's/^Filed issue #\([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$issue" ] || fail "the issue number was not read from: $(printf '%s' "$out" | tail -n 1)"

root=$(git rev-parse --show-toplevel)
base=${PREPARE_WORKTREES:-$(dirname "$root")/worktrees/$(basename "$root")}
wt="$base/$branch"
mkdir -p "$base"
git fetch -q origin main >/dev/null 2>&1 || true
git worktree add "$wt" -b "$branch" "$ref" >/dev/null 2>&1 || fail "the worktree $wt could not be made for issue #$issue"
sh "$wt/plugin/scripts/release/bump.sh" "$next" >/dev/null 2>&1 || fail "the version bump failed in $wt for issue #$issue"
mkdir -p "$wt/.scratch"
printf 'Releases the plugin as %s.\n\nCloses #%s\n\nSpec: specs/constitution.md\n' "$next" "$issue" > "$wt/.scratch/body.md"
git -C "$wt" add -A >/dev/null 2>&1
git -C "$wt" commit -q -m "Release the plugin as $next" >/dev/null 2>&1 || fail "the commit failed in $wt for issue #$issue"
git -C "$wt" push -q -u origin "$branch" >/dev/null 2>&1 || fail "the branch could not be pushed from $wt for issue #$issue"
pr=$(cd "$wt" && sh "${PR_OPEN:-scripts/pr-open.sh}" "Release the plugin as $next" .scratch/body.md 2>&1 | sed -n 's/^Opened pull request #\([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$pr" ] || fail "the pull request could not be opened from $wt for issue #$issue"
say "opened pull request #$pr for $next (issue #$issue)"
