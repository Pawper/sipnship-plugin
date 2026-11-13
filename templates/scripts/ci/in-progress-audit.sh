#!/bin/sh
# For the nightly audit: every open issue whose State is In progress while
# nothing works on it, one line each, "#N: title, quiet for H hours." An issue
# is In progress only while something is working on it; when its landed part
# did not put it back (the service does that on the merge event), this names
# it so it is not left stuck. Nothing works on it when no open pull request
# names it (Closes, Fixes, Part of) and nothing touched it for HOURS hours
# (default 2: no comment, label or edit on the issue). REST only, two calls
# for the whole list; prints nothing when all is well or GitHub cannot be
# asked. Needs GH_REPO. NOW (epoch seconds) is for tests.
repo=${GH_REPO:-}
[ -n "$repo" ] || exit 0
hours=${1:-2}
now=${NOW:-$(date +%s)}
issues=$(gh api "repos/$repo/issues?state=open&labels=state:in-progress&per_page=100" --paginate \
  --jq '.[] | select(.pull_request | not) | [.number, .title, (.updated_at | fromdateiso8601)] | @tsv' 2>/dev/null | tr -d '\r') || exit 0
[ -n "$issues" ] || exit 0
bodies=$(gh api "repos/$repo/pulls?state=open&per_page=100" --paginate --jq '.[] | (.body // "") | gsub("\n"; " ")' 2>/dev/null | tr -d '\r') || exit 0
printf '%s\n' "$issues" | while IFS='	' read -r n title at; do
  [ -n "$n" ] || continue
  age=$(( (now - at) / 3600 ))
  [ "$age" -ge "$hours" ] || continue
  if printf '%s\n' "$bodies" | grep -Eiq "(close[sd]?|fix(e[sd])?|resolve[sd]?|part of|refs?)[: ]+#$n([^0-9]|\$)"; then continue; fi
  printf '#%s: %s, quiet for %s hours.\n' "$n" "$title" "$age"
done
exit 0
