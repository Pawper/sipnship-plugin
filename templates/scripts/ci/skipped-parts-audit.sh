#!/bin/sh
# scripts/ci/skipped-parts-audit.sh [SINCE]
# Pull requests merged since SINCE (default: one day ago, audit.yml's own
# "since") whose own run had to prove a test part its files called for
# (own_run_decide or full_run_decide said so, from the files it changed and
# the labels it carried) but the part's own check did not pass on the
# commit that merged (#2318): "green" with a needed part skipped is not
# green, and a landing should never have reached main that way. One line
# each, naming the pull request, the part and the rule that called for it
# (required_parts_say); nothing when every landing's required parts passed.
# Needs gh, signed in; REST and the gh cli, no state of its own.
here=$(dirname "$0")
. "$here/lib.sh"; . "$here/gate-lib.sh"; . "$here/required-parts-lib.sh"
since=${1:-$(date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)}
[ -f "$here/classes.txt" ] || exit 0
rules=$(cat "$here/classes.txt")
merged=$(gh pr list --state merged --search "merged:>=$since" --limit 100 --json number,headRefOid,headRefName,labels \
  --jq '.[] | [.number, .headRefOid, .headRefName, ([.labels[].name] | join(","))] | @tsv' 2>/dev/null) || exit 0
printf '%s\n' "$merged" | tr -d '\r' | while IFS="$(printf '\t')" read -r sp_num sp_sha sp_ref sp_labels; do
  [ -n "$sp_num" ] || continue
  files=$(gh pr diff "$sp_num" --name-only 2>/dev/null)
  [ -n "$files" ] || continue
  classes=$(classify_paths "$files" "$rules")
  own=$(own_run_decide "$classes" "$rules")
  full=$(full_run_decide "$sp_ref" "$sp_labels" "$classes")
  [ "$own" = yes ] || [ "$full" = yes ] || continue
  checks=$(gh api "repos/{owner}/{repo}/commits/$sp_sha/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)"' 2>/dev/null)
  miss=$(required_parts_say "$classes" "$rules" "$checks")
  [ -z "$miss" ] || printf '#%s: %s\n' "$sp_num" "$(printf '%s\n' "$miss" | head -n 1)"
done
