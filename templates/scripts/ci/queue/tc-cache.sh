#!/bin/sh
# The batch checks main's type-check once per state of main. A batch that
# stops before it merges anything (a held request, an empty pairing) is run
# again on the same main, and the whole-base type-check took the same time
# to give the same answer. Sourced by scripts/ci/merge-queue.sh; functions
# only.
#
#   tc_base_ok WT PATHS   0 when main's tree in WT type-checks: at once when
#                         that exact tree already passed here and the installed
#                         packages are not stale, otherwise by typecheck_ok
#                         (batch.sh), remembering a pass in
#                         .scratch/queue/base-checked. A red base is never
#                         remembered, and nothing is skipped by time.

tc_base_ok() {
  tb_tree=$(git -C "$1" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
  if [ -n "$tb_tree" ] && [ ! -s "$flaky_dir/modules.stale" ] && [ "$(cat "$flaky_dir/base-checked" 2>/dev/null)" = "$tb_tree" ]; then
    echo "  main is unchanged since its type-check last passed here; not checked again"
    : > "$flaky_dir/typecheck.err"
    return 0
  fi
  typecheck_ok "$2" "$1" || { rm -f "$flaky_dir/base-checked" 2>/dev/null || :; return 1; }
  [ -z "$tb_tree" ] || printf '%s\n' "$tb_tree" > "$flaky_dir/base-checked" 2>/dev/null || true
  return 0
}
