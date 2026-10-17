#!/bin/sh
# The GitHub API budget in one line: "GraphQL 4,120 of 5,000 left, resets
# 09:19Z (in 23 min); REST 3,469 of 5,000 left." gh issue, gh pr, gh
# project and gh search spend GraphQL points; gh api on a REST path spends
# REST ones. Seven agents and a queue share the hour's 5,000, so the reading
# (from gh api rate_limit, itself free) is cached for a minute in
# .scratch/gh-budget.txt, where the plugin's require-gh-budget hook reads it.
# Usage: sh scripts/gh-budget.sh            print the line
#        sh scripts/gh-budget.sh --check    exit 1 when under GH_BUDGET_MIN (500) GraphQL points
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
file=$root/.scratch/gh-budget.txt
now=$(date +%s)
floor=${GH_BUDGET_MIN:-500}
rec=$(head -n 1 "$file" 2>/dev/null | tr -d '\r' | awk -F'\t' -v now="$now" 'NF >= 7 && now - $1 >= 0 && now - $1 < 60 { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }')
if [ -z "$rec" ]; then
  command -v gh >/dev/null 2>&1 || { echo "gh is not installed; no budget to read." >&2; exit 2; }
  rec=$(gh api rate_limit --jq '[.resources.graphql.remaining, .resources.graphql.limit, .resources.graphql.reset, .resources.core.remaining, .resources.core.limit, .resources.core.reset] | @tsv' 2>/dev/null | tr -d '\r') || rec=""
  [ -n "$rec" ] || { echo "gh api rate_limit failed; is gh signed in?" >&2; exit 2; }
  mkdir -p "$root/.scratch" 2>/dev/null && printf '%s\t%s\n' "$now" "$rec" > "$file" 2>/dev/null
fi
printf '%s\n' "$rec" | awk -F'\t' -v now="$now" -v floor="$floor" '
  function commas(n,  s) { s = sprintf("%d", n); while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]$|[0-9][0-9][0-9],/, ",&", s); return s }
  { mins = int(($3 - now + 59) / 60); if (mins < 0) mins = 0
    printf "GraphQL %s of %s left, resets %s (in %d min); REST %s of %s left.", commas($1), commas($2), sprintf("%02d:%02dZ", int(($3 % 86400) / 3600), int(($3 % 3600) / 60)), mins, commas($4), commas($5)
    if ($1 + 0 < floor) printf " Low: use the REST forms (scripts/issue-open.sh, pr-open.sh, pr-checks.sh, gh api) and wait for the reset; never retry before it."
    printf "\n" }'
if [ "$1" = --check ]; then
  [ "$(printf '%s\n' "$rec" | cut -f1)" -ge "$floor" ] || exit 1
fi
