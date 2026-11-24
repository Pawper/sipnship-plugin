#!/bin/sh
# For the nightly audit: every open issue whose "What done looks like" lines are each built, one line each,
# `#N "Title" has every line of its "What done looks like" built and is still open.` A line is built when a
# landed pull request's body or a comment carries `Built #N: <the line, word for word>` (the card's own
# reading, packages/core/src/issue-progress.ts); closing stays strict, so a change that only builds the last
# line leaves its issue open, and this names it so the drive can close it, with a comment saying why.
#
# REST only: one call for the open issues, one for the repository's comments and one for its merged pull
# requests, however long the list. Prints nothing when all is well or GitHub cannot be asked. Needs GH_REPO.
repo=${GH_REPO:-}
[ -n "$repo" ] || exit 0
us=$(printf '\037')
tab=$(printf '\t')
issues=$(gh api "repos/$repo/issues?state=open&per_page=100" --paginate \
  --jq ".[] | select(.pull_request == null) | [.number, .title, ((.body // \"\") | gsub(\"\r\"; \"\") | gsub(\"\n\"; \"$us\"))] | @tsv" 2>/dev/null | tr -d '\r') || exit 0
[ -n "$issues" ] || exit 0
mark_filter='select(. != null) | gsub("\r"; "") | split("\n")[] | select(test("^\\s*Built #[0-9]+:"))'
comments=$(gh api "repos/$repo/issues/comments?per_page=100" --paginate --jq ".[].body | $mark_filter" 2>/dev/null) || exit 0
pulls=$(gh api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100" --paginate \
  --jq ".[] | select(.merged_at != null) | .body | $mark_filter" 2>/dev/null) || exit 0
# One "N<tab>line" per mark, the line's spaces collapsed to one as the card reads it.
marks=$(printf '%s\n%s\n' "$comments" "$pulls" | tr -d '\r' | sed 's/[[:space:]][[:space:]]*/ /g' \
  | sed -n 's/^ *Built #\([0-9][0-9]*\): *\(.*[^ ]\) *$/\1'"$tab"'\2/p')
[ -n "$marks" ] || exit 0
printf '%s\n' "$issues" | while IFS="$tab" read -r n title body; do
  [ -n "$n" ] || continue
  lines=$(printf '%s\n' "$body" | tr "$us" '\n' | awk '
    /^#+[ \t]*What done/ { g = 1; next }
    g && /^#+[ \t]/ { g = 0 }
    g && /^[ \t]*-[ \t]+/ { sub(/^[ \t]*-[ \t]+/, ""); gsub(/[ \t]+/, " "); sub(/ $/, ""); print }')
  [ -n "$lines" ] || continue
  all=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$marks" | grep -qxF "$n$tab$line" || { all=0; break; }
  done <<EOT
$lines
EOT
  [ "$all" = 1 ] || continue
  printf '#%s "%s" has every line of its "What done looks like" built and is still open.\n' "$n" "$title"
done
exit 0
