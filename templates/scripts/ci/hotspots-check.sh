#!/bin/sh
# Fail when a pull request grows a source file past its size limit, and warn
# (as a comment on the pull request) when a file nears the limit or when
# two or more other open pull requests edit a file this one edits. The
# limits and the shrink-only list are scripts/ci/hotspots.txt; without the
# file this check always passes.
# Usage: sh scripts/ci/hotspots-check.sh BASE HEAD [PR_NUMBER]
# HOTSPOTS_OTHERS names a file of "NUMBER<TAB>PATH" lines standing in for
# the other open pull requests (the tests use it); otherwise they are read
# over REST when a pull request number is given and gh is there.
here=$(dirname "$0")
. "$here/hotspots-lib.sh"

[ -f "$here/hotspots.txt" ] || { echo "Hotspots check passed (no hotspots.txt)."; exit 0; }
spec=$(cat "$here/hotspots.txt")
base=$1; head=$2; pr=$3

lines_at() { git show "$1:$2" 2>/dev/null | awk 'END { print NR }'; }

changed=$(git diff --name-only --diff-filter=AMR "$base" "$head" | tr -d '\r')
results=$(printf '%s\n' "$changed" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -n "$(hotspot_limit "$p" "$spec")" ] || continue
  new=$(lines_at "$head" "$p")
  if git cat-file -e "$base:$p" 2>/dev/null; then old=$(lines_at "$base" "$p"); else old=0; fi
  hotspot_verdict "$p" "$spec" "$old" "$new"
done)

others=${HOTSPOTS_OTHERS:+$(cat "$HOTSPOTS_OTHERS")}
if [ -z "$others" ] && [ -n "$pr" ] && command -v gh >/dev/null 2>&1; then
  others=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=40" --jq '.[].number' 2>/dev/null | while read -r n; do
    [ "$n" = "$pr" ] && continue
    gh api "repos/{owner}/{repo}/pulls/$n/files?per_page=100" --jq ".[].filename | \"$n\t\" + ." 2>/dev/null
  done)
fi
overlaps=$(hotspot_overlap_rows "$changed" "$others" 2 | while IFS="$(printf '\t')" read -r p nums; do
  [ -n "$p" ] || continue
  printf 'warn\t%s\n' "$(hotspot_overlap_say "$p" "$nums")"
done)

all=$(printf '%s\n%s\n' "$results" "$overlaps" | awk 'NF')
printf '%s\n' "$all" | awk -F'\t' '$1 == "warn" { print "::warning::" $2 }'

# One comment, kept current, when there is anything to say.
if [ -n "$pr" ] && [ -n "$GH_TOKEN" ] && command -v gh >/dev/null 2>&1; then
  marker='<!-- hotspots -->'
  text=$(printf '%s\n' "$all" | awk -F'\t' '{ print "- " $2 }')
  old=$(gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --jq ".[] | select(.body | startswith(\"$marker\")) | .id" 2>/dev/null | head -n 1)
  if [ -n "$text" ]; then body="$marker
Size and overlap notes for this change:
$text"; elif [ -n "$old" ]; then body="$marker
Nothing to flag now."; else body=""; fi
  if [ -n "$body" ]; then
    if [ -n "$old" ]; then gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$old" -f body="$body" >/dev/null 2>&1 || true
    else gh api "repos/{owner}/{repo}/issues/$pr/comments" -f body="$body" >/dev/null 2>&1 || true; fi
  fi
fi

fails=$(printf '%s\n' "$all" | awk -F'\t' '$1 == "fail" { print $2 }')
if [ -n "$fails" ]; then
  printf '%s\n' "$fails" >&2
  exit 1
fi
echo "Hotspots check passed."
