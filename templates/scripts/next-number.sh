#!/bin/sh
# Reserve the next free number for a numbered file, across main and every
# open pull request, so two agents never take the same one.
#
# Usage: sh scripts/next-number.sh migration
#
# The kinds and where their files live are in .claude/numbering.txt, one
# per line: "KIND GLOB", for example
#   migration supabase/migrations/*.sql
# It reads the files on the default branch (local git, after a fetch) and
# the files every open pull request adds (one gh call), and prints the next
# number after the largest, padded the same way.
#
# For anything that does not have to run in order, use the issue number
# instead: a setup step "for #123", a task "#123". Issue numbers never
# collide, and nothing has to be reserved.
set -e
here=$(dirname "$0")
. "$here/ci/numbering-lib.sh"

kind=$1
[ -n "$kind" ] || { echo "Usage: sh scripts/next-number.sh KIND   (kinds are listed in .claude/numbering.txt)" >&2; exit 2; }
[ -f .claude/numbering.txt ] || { echo "There is no .claude/numbering.txt yet; add a line such as: migration supabase/migrations/*.sql" >&2; exit 2; }
glob=$(numbering_glob "$(cat .claude/numbering.txt)" "$kind")
[ -n "$glob" ] || { echo "No kind \"$kind\" in .claude/numbering.txt." >&2; exit 2; }

prefix=$(numbering_prefix "$(cat .claude/numbering.txt)" "$kind")
if [ -n "$prefix" ]; then
  # An ID inside one file: read that file on main and on the head of every
  # open pull request. One gh call for the numbers, one fetch for all heads.
  git fetch -q origin 2>/dev/null || true
  base_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  texts=$(git show "$base_ref:$glob" 2>/dev/null || true)
  open=""
  command -v gh >/dev/null 2>&1 && open=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[].number' 2>/dev/null || true)
  if [ -n "$open" ]; then
    specs=""; for n in $open; do specs="$specs +refs/pull/$n/head:refs/remotes/origin/pr/$n"; done
    git fetch -q origin $specs 2>/dev/null || true
    for n in $open; do texts="$texts
$(git show "refs/remotes/origin/pr/$n:$glob" 2>/dev/null || true)"; done
  fi
  texts="$texts
$(cat "$glob" 2>/dev/null || true)"
  next_free_id "$(id_definitions "$texts" "$prefix")" "$prefix"
  exit 0
fi

default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
git fetch -q origin 2>/dev/null || true
on_main=$(git ls-tree -r --name-only "$default" 2>/dev/null || true)
in_prs=""
# gh only with a GitHub remote: without one gh asks which repository and waits.
# This one stays GraphQL: the files of every open pull request in one call,
# where REST would be one call per pull request.
case "$(git remote get-url origin 2>/dev/null)" in
  *github.com*) command -v gh >/dev/null 2>&1 && in_prs=$(gh pr list --state open --limit 100 --json files --jq '.[].files[].path' 2>/dev/null || true) ;;
esac
here_now=$(git ls-files --others --cached 2>/dev/null || true)

all=$(printf '%s\n%s\n%s\n' "$on_main" "$in_prs" "$here_now")
found=$(numbers_in "$all" "$glob")
if [ -z "$(printf '%s' "$found" | tr -d ' \n')" ]; then
  guess=$(migration_glob_guess "$all")
  if [ -n "$guess" ] && [ "$guess" != "$glob" ]; then
    echo "No file matches \"$glob\" from .claude/numbering.txt, but $guess does. Fix the $kind line there to: $kind $guess" >&2
    exit 2
  fi
  echo "No file matches \"$glob\" yet; this is the first $kind." >&2
fi
next=$(next_free_number "$found")
echo "$next"
