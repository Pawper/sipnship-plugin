#!/bin/sh
# For the nightly audit: every open pull request the closes check would fail,
# one line each, "#N "Title" names no issue it closes, so the closes check
# would fail it." A change opened before the rule fails the moment someone
# approves it, which looks approved and stuck; this names it a night early,
# while the agent can still give it the issue it closes.
#
# The rule is the check's own: a line reading Closes, Fixes or Resolves with
# an issue number. The queue's own batch carries none and is never a failure,
# so a head branch starting "batch" or "merge-queue" is skipped. REST only,
# one call for the whole list; prints nothing when all is well or GitHub
# cannot be asked. Needs GH_REPO.
repo=${GH_REPO:-}
[ -n "$repo" ] || exit 0
us=$(printf '\037')
pulls=$(gh api "repos/$repo/pulls?state=open&per_page=100" --paginate \
  --jq ".[] | [.number, .title, .head.ref, ((.body // \"\") | gsub(\"\r\"; \"\") | gsub(\"\n\"; \"$us\"))] | @tsv" 2>/dev/null | tr -d '\r') || exit 0
[ -n "$pulls" ] || exit 0
printf '%s\n' "$pulls" | while IFS='	' read -r n title branch body; do
  [ -n "$n" ] || continue
  case $branch in batch*|merge-queue*) continue ;; esac
  if printf '%s\n' "$body" | tr "$us" '\n' | grep -Eiq '^[[:space:]]*(closes|fixes|resolves) +#[0-9]+'; then continue; fi
  printf '#%s “%s” names no issue it closes, so the closes check would fail it.\n' "$n" "$title"
done
exit 0
