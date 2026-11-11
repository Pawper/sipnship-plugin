#!/bin/sh
# Lands a rule switch in the repository. The app (or a person's terminal,
# sh scripts/rules.sh off|on) sets the repository variable RULES_OFF; this
# makes .claude/rules-off.txt and the rules table in AGENTS.md say the same,
# in one small pull request, and asks the queue to land it first ("Land
# this next", because it changes a rule). It runs on the project's own
# runners: the rules-sync workflow on the rules:sync label, and the queue
# drain's first step as the fallback when that run was missed. Nothing to
# do when the file already matches.
#
# Usage: sh scripts/ci/rules-sync.sh
#   RULES_OFF       the variable's value (the workflow passes it)
#   RULES_SYNC_DAY  the day to write for a rule newly off (default: today)
#   RULES_SYNC_DRY  "yes": print the change and the title, touch nothing
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(cd "$(dirname "$0")/../.." && pwd)
cd "$top" || exit 1
. "$top/scripts/ci/rules-lib.sh"
file=.claude/rules-off.txt

want=$(printf '%s\n' ${RULES_OFF:-} | rules_ids_of | tr '\n' ' ' | sed 's/ $//')
have=""
[ -f "$file" ] && have=$(rules_ids_of < "$file" | tr '\n' ' ' | sed 's/ $//')
if [ "$want" = "$have" ]; then
  echo "The rule switches are already in step with the repository."
  exit 0
fi

day=${RULES_SYNC_DAY:-}
if [ -z "$day" ]; then
  # Git Bash's own clock is not the owner's local day here; ask Windows.
  day=$(powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd" 2>/dev/null | tr -d '\r')
  [ -n "$day" ] || day=$(date +%F)
fi
title=$(rules_sync_title "$have" "$want")
text=$(rules_off_text "$want" "$( [ -f "$file" ] && cat "$file" )" "$day")
if [ "${RULES_SYNC_DRY:-}" = yes ]; then
  printf '%s\n\n%s\n' "$title" "$text"
  exit 0
fi

branch="rules-sync/$(printf '%s' "$want" | tr ' ' '-' | cut -c1-60)-$(printf '%s' "$want" | cksum | cut -d' ' -f1)"
[ -n "$want" ] || branch="rules-sync/all-on-$(printf '%s' "$have" | cksum | cut -d' ' -f1)"
open=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select(.head.ref | startswith("rules-sync/")) | "\(.number) \(.head.ref)"')
if printf '%s\n' "$open" | grep -q " $branch\$"; then
  echo "A pull request for this change is already open: $(printf '%s\n' "$open" | grep " $branch\$" | cut -d' ' -f1 | sed 's/^/#/')."
  exit 0
fi

orig=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
trap 'git checkout -q "$orig" 2>/dev/null' EXIT
git fetch -q origin main || exit 1
git checkout -q -B "$branch" origin/main || exit 1
mkdir -p .claude
printf '%s\n' "$text" > "$file"
sh scripts/rules.sh build || exit 1
git add -A
git commit -q -m "$title" -m "Written by the rule-switch sync from the repository's switches." || { echo "Nothing changed; nothing to land."; exit 0; }
git push -q origin "HEAD:refs/heads/$branch" || exit 1

mkdir -p .scratch
printf '%s\n' "Spec: specs/016-rule-switches" "" \
  "The rules that are off in this project were changed on the Rules tab. This brings the switches file and the rules table in line, so the hooks, the checks and what your agent reads all change in the same commit. Nothing else is in it." > .scratch/rules-sync-body.md
out=$(sh scripts/pr-open.sh "$title" .scratch/rules-sync-body.md main "$branch") || { printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out"
pr=$(printf '%s\n' "$out" | sed -n 's/.*#\([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$pr" ] || exit 0

# A change still open for an older version of the switches is replaced.
for old in $(printf '%s\n' "$open" | cut -d' ' -f1); do
  gh api -X POST "repos/{owner}/{repo}/issues/$old/comments" -f body="Replaced by #$pr, which carries the rule switches as they are now." >/dev/null
  gh api -X PATCH "repos/{owner}/{repo}/pulls/$old" -f state=closed >/dev/null
done

gh api -X POST "repos/{owner}/{repo}/issues/$pr/comments" -f body="Queue request: land-now #$pr by rules-sync: First because it changes a rule" >/dev/null
echo "Asked the queue to land #$pr first."
