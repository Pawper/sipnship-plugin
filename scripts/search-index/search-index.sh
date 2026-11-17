#!/bin/sh
# Leave the folders agents work in out of Windows Search, and say which are
# still in. Does nothing on a machine that is not Windows.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/search-index/search-index.sh" [exclude|check]
# The folders are the project's worktrees folder (as scripts/drive/worktree-access.sh
# finds it) and the queue's batch folder beside the project. `exclude` (the
# default) adds the exclusion rule; `check` only reads. Prints one line per
# folder as "NAME<TAB>out|in|unknown".
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../hooks/scripts/lib.sh"
. "$here/../drive/worktree-access-lib.sh"
. "$here/search-index-lib.sh"
SEARCH_INDEX_HOME=$here
export SEARCH_INDEX_HOME
act=${1:-exclude}
[ "$(search_index_applies "$(uname -s 2>/dev/null)")" = yes ] || exit 0
conf=""
[ -f .claude/project-drive.json ] && conf=$(json_field "$(cat .claude/project-drive.json)" worktreesDir)
main=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git/*$##')
[ -n "$main" ] || main=$(pwd)
wt=$(worktrees_dir_pick "$conf" "$(git worktree list --porcelain 2>/dev/null)" "$main")
batch="${main%/*}/${main##*/}-wt-batch"
for d in "$wt" "$batch"; do
  [ -d "$d" ] || continue
  if [ "$act" = check ]; then s=$(search_index_state "$d"); else s=$(search_index_exclude "$d"); fi
  printf '%s\t%s\n' "${d##*/}" "$s"
done
exit 0
