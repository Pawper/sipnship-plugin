#!/bin/sh
# PreToolUse hook for Bash: refuses a GraphQL gh command (gh issue, gh pr,
# gh project, gh search, gh api graphql) when fewer than GH_BUDGET_MIN
# (default 500) of the hour's GraphQL points are left, saying when the
# window resets. The rule it enforces: seven agents and a queue share one
# budget; when it is nearly spent, the REST form or the wait is the move,
# never a retry. The reading comes from gh api rate_limit, itself free,
# cached for a minute in .scratch/gh-budget.txt.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/bounded-lib.sh"
. "$here/budget-rest-lib.sh"
. "$here/refusal-log.sh"
. "$here/rule-switch.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0

hit=$(gh_graphql_reason "$cmd")
rest_hit=
[ -n "$hit" ] || rest_hit=$(gh_rest_read_reason "$cmd")
[ -n "$hit" ] || [ -n "$rest_hit" ] || exit 0

root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] || root=.
rec=$(budget_read "$root")
# REST (#2558): a read that is not needed to land or recover waits when the hour's REST requests run low; a write, and
# the free reading of the budget itself, never do. The app's reads and the drive's scripts share the same hour.
if [ -n "$rest_hit" ]; then
  [ -n "$rec" ] || exit 0
  [ "$(budget_rest_low "$rec" "${GH_REST_BUDGET_MIN:-150}")" = yes ] || exit 0
  rule_gate github-budget
  printf '%s\n' "Blocked \`$rest_hit\` because the hour's REST budget is nearly spent and a read that is not needed to land or recover would take it from everyone: $(budget_rest_line "$rec" "$(date +%s)") Wait for that time; a push, a merge or a comment still goes through." >&2
  exit 2
fi
[ -n "$rec" ] || exit 0
floor=${GH_BUDGET_MIN:-500}
[ "$(budget_low "$rec" "$floor")" = yes ] || exit 0
rule_gate github-budget

printf '%s\n' "Blocked \`$hit\` because the hour's GraphQL budget is nearly spent and the next call would fail for everyone: $(budget_line "$rec" "$(date +%s)" "$floor") A one-off read is \`gh api repos/{owner}/{repo}/issues/N\`; \`sh scripts/gh-budget.sh\` prints the budget again." >&2
exit 2
