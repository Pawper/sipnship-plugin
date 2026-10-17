#!/bin/sh
# Fail when a change leaves two numbered files with the same number, or
# adds a task with a running number instead of an issue number.
#
# Usage: sh scripts/ci/numbering-check.sh BASE HEAD
#
# Numbered kinds come from .claude/numbering.txt ("KIND GLOB"). Task files
# come from scripts/ci/task-files.txt, one path per line; empty means no
# task-file check. Runs in CI on every pull request, so a batch that
# merged two pull requests which each took 0022 fails before it reaches main.
here=$(dirname "$0")
. "$here/numbering-lib.sh"

base=${1:-origin/main}; head=${2:-HEAD}
# By hand, with no arguments, it compares the checkout with origin/main.
fail=0

if [ -f .claude/numbering.txt ]; then
  files=$(git ls-tree -r --name-only "$head")
  tr -d '\r' < .claude/numbering.txt | while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    kind=${line%% *}; glob=$(numbering_glob "$line" "$kind"); prefix=$(numbering_prefix "$line" "$kind")
    if [ -n "$prefix" ]; then
      dups=$(duplicate_ids "$(git show "$head:$glob" 2>/dev/null)" "$prefix")
      old=$(duplicate_ids "$(git show "$base:$glob" 2>/dev/null)" "$prefix")
      new=$(printf '%s\n' "$dups" | while IFS= read -r d; do [ -n "$d" ] && ! printf '%s\n' "$old" | grep -qx "$d" && echo "$d"; done)
      if [ -n "$old" ]; then
        echo "Cleanup, not this change's fault: $glob already defines $(printf '%s' "$old" | tr '\n' ' ' | sed 's/ $//') twice on $base. Remove the stale row once, in its own pull request." >&2
      fi
      if [ -n "$new" ]; then
        echo "$glob defines $(printf '%s' "$new" | tr '\n' ' ' | sed 's/ $//') twice; two pull requests took the same $kind number. Renumber the newer one with: sh scripts/next-number.sh $kind" >&2
        echo fail
      fi
      continue
    fi
    dups=$(duplicate_numbers "$files" "$glob")
    old=$(duplicate_numbers "$(git ls-tree -r --name-only "$base" 2>/dev/null)" "$glob" | cut -f1)
    if [ -n "$old" ]; then
      echo "Cleanup, not this change's fault: two $kind files already share $(printf '%s' "$old" | tr '\n' ' ' | sed 's/ $//') on $base. Renumber one in its own pull request." >&2
      dups=$(printf '%s\n' "$dups" | awk -F'\t' -v old=" $(printf '%s' "$old" | tr '\n' ' ') " 'NF && index(old, " " $1 " ") == 0')
    fi
    if [ -n "$dups" ]; then
      printf '%s\n' "$dups" | while IFS="$(printf '\t')" read -r num names; do
        echo "Two $kind files share the number $num: $names. Renumber the newer one with: sh scripts/next-number.sh $kind" >&2
      done
      echo fail
    fi
  done | grep -q '^fail$' && fail=1
fi

if [ -f "$here/task-files.txt" ]; then
  for f in $(tr -d '\r' < "$here/task-files.txt" | sed '/^#/d; /^[ \t]*$/d'); do
    added=$(git diff "$base" "$head" -- "$f" 2>/dev/null | sed -n 's/^+\([^+]\)/\1/p')
    bad=$(running_task_lines "$added")
    if [ -n "$bad" ]; then
      echo "$f gains a task with a running number, which the next pull request will take too: $(printf '%s\n' "$bad" | head -n 2 | tr '\n' ' '). Name it by its issue number instead, for example \"#123 Add the exporter\"." >&2
      fail=1
    fi
  done
fi

[ "$fail" -eq 0 ] && echo "Numbering check passed."
exit "$fail"
