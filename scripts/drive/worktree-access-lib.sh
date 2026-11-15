#!/bin/sh
# Helpers for the drive's check that it can make a worktree before it starts
# an agent (specs/023-drive-on-work). A drive tick woken on a self-hosted
# runner runs as the runner's service account, which may not reach the folder
# the project keeps its worktrees in; every agent it started would fail at
# its first step. Everything here is pure except worktree_probe.

# worktrees_dir_from PORCELAIN
# PORCELAIN is `git worktree list --porcelain`. Print the folder that holds
# the project's linked worktrees: the parent they share. The first entry is
# the main checkout and Claude Code's own `.claude/worktrees` are left out.
# Nothing when no linked worktree exists or they do not share one parent.
worktrees_dir_from() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^worktree / { n++; if (n == 1) next; p = substr($0, 10); if (p ~ /\/\.claude\/worktrees\//) next
      sub(/\/[^\/]*$/, "", p); if (dir == "") dir = p; else if (dir != p) mixed = 1 }
    END { if (dir != "" && !mixed) print dir }'
}

# worktrees_dir_pick CONFIGURED PORCELAIN MAIN_ROOT
# The project's worktrees folder: the `worktreesDir` the project's drive
# config names, else the parent its existing worktrees share, else the
# folder named like the project in a `worktrees` folder beside the project's
# own (MAIN_ROOT/../worktrees/NAME).
worktrees_dir_pick() {
  if [ -n "$1" ]; then printf '%s\n' "$1"; return 0; fi
  _wd=$(worktrees_dir_from "$2")
  if [ -n "$_wd" ]; then printf '%s\n' "$_wd"; return 0; fi
  _wm=${3%/}
  printf '%s/worktrees/%s\n' "${_wm%/*}" "${_wm##*/}"
}

# worktree_probe DIR
# Print "ok" when a worktree could be made in DIR, else "denied". It makes one
# fixed folder, DIR/.write-probe, and writes an empty file in it, the same
# kind of right `git worktree add` needs, and leaves it there: the same two
# names every time, so nothing piles up and nothing is deleted. A DIR that
# does not exist yet is made (git makes it too); when that fails it is denied.
worktree_probe() {
  mkdir -p "$1/.write-probe" 2>/dev/null || { echo denied; return 0; }
  : >> "$1/.write-probe/probe" 2>/dev/null || { echo denied; return 0; }
  echo ok
}

# worktree_access_report PROBE DIR ACCOUNT
# PROBE is worktree_probe's word. Prints "ok" or, when denied, three lines
# the drive passes on: "held: ..." (the approval's line), "waits: ..." (the
# round's line on the dashboard, plain words, no account or path) and
# "detail: ..." (the secondary line, which may name the account and folder).
worktree_access_report() {
  if [ "$1" = ok ]; then echo ok; return 0; fi
  echo "held: no agent can be started from here yet, because this machine's scheduled run is not allowed to make working folders"
  echo "waits: a session on your own machine to start the agents; proposing, landing and tidying go on meanwhile"
  echo "detail: could not create files in ${2:-the worktrees folder} as ${3:-the account this run uses}; the fix is in SETUP.md"
}

# hold_no_worktree GOALS ACCESS
# GOALS are approved goal lines; ACCESS is worktree_access_report's output.
# When access is fine the goals print unchanged. Otherwise every goal that
# needs a worktree (dispatch, merge-main, fix, start-next, start-now) is
# dropped and one "held:" line takes its place; goals that need none go
# ahead. The detail line is the drive's to post, never a goal.
hold_no_worktree() {
  case "$2" in
    ok*|'') printf '%s\n' "$1"; return 0 ;;
  esac
  _why=$(printf '%s\n' "$2" | sed -n 's/^held: //p' | head -n 1)
  printf '%s\n' "$1" | awk -v why="$_why" '
    /^(dispatch|merge-main|fix|start-next|start-now) / { held++; next }
    NF > 0 { print }
    END { if (held) print "held: " held " goal(s) not started, " why }'
}
