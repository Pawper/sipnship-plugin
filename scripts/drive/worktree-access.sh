#!/bin/sh
# Can this run make a worktree? The drive runs this before it starts any
# agent: an agent whose worktree cannot be made fails at its first step. It
# prints "ok", or "held:", "waits:" and "detail:" lines the drive passes on
# (worktree-access-lib.sh). It changes nothing but the one probe folder.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/worktree-access.sh"
# The folder is `worktreesDir` in .claude/project-drive.json when set, else
# where the project's existing worktrees live, else a `worktrees` folder
# beside the project. WORKTREE_ACCESS_CHECK=off prints ok without probing
# (the plugin's own tests, which must not write beside the checkout).
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/worktree-access-lib.sh"
if [ "${WORKTREE_ACCESS_CHECK:-}" = off ]; then echo ok; exit 0; fi
conf=""
[ -f .claude/project-drive.json ] && conf=$(json_field "$(cat .claude/project-drive.json)" worktreesDir)
main=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git/*$##')
[ -n "$main" ] || main=$(pwd)
dir=$(worktrees_dir_pick "$conf" "$(git worktree list --porcelain 2>/dev/null)" "$main")
probe=$(worktree_probe "$dir")
# On Windows the worktrees and batch folders go out of the search index here,
# with no step for the builder (scripts/search-index/search-index.sh).
[ "$probe" = ok ] && sh "$here/../search-index/search-index.sh" exclude >/dev/null 2>&1
worktree_access_report "$probe" "$dir" "$(whoami 2>/dev/null)"
