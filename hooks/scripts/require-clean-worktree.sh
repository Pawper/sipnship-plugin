#!/bin/sh
# Stop and SubagentStop hook: a clean folder is part of "done".
#
# It acts only inside a linked worktree, where an agent works on one task.
# In the main checkout a person is usually mid-work, and it stays out of
# the way. Before the agent may finish it checks three things:
#   1. nothing modified or untracked outside the scratch folder (.scratch/);
#   2. no images, video or build output left in the worktree;
#   3. no process still running from the worktree folder, and at the
#      session'\''s end none started by this session that runs a script
#      (a check run as "sh scripts/ci/design-check.sh" names no folder).
# It refuses once, names what it found, and says what to do. It kills
# nothing and removes nothing. If the agent stops again without fixing it,
# the second stop goes through, so a session can never be trapped.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"
. "$here/worktree-lib.sh"

input=$(cat)
case "$input" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] && cd "$root" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
common=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
# The main checkout has the same git dir and common dir; a linked worktree does not.
[ "$(cd "$gitdir" 2>/dev/null && pwd)" != "$(cd "$common" 2>/dev/null && pwd)" ] || exit 0

problems=""
dirty=$(dirty_non_scratch "$(git status --porcelain --untracked-files=all 2>/dev/null)")
if [ -n "$dirty" ]; then
  count=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
  media=$(stray_media "$dirty")
  first=$(printf '%s\n' "$dirty" | head -n 5 | tr '\n' ' ')
  problems="$count file(s) outside .scratch/ are uncommitted ($first); commit them, or list them in the pull request as deliberately left out, or move scratch into .scratch/."
  if [ "$media" -gt 0 ]; then
    problems="$problems $media of them are images or build output, which belong in the work folder outside the repository, not in a worktree."
  fi
fi

here_path=$(pwd -W 2>/dev/null || pwd)
if command -v powershell >/dev/null 2>&1 && [ -n "$WINDIR" ]; then
  plist=$(powershell -NoProfile -Command 'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId)`t$($_.ParentProcessId)`t$($_.CommandLine)" }' 2>/dev/null)
  # the process list holds Windows ids; $$ is the MSYS one
  me=$(ps -p $$ 2>/dev/null | awk 'NR == 2 { print $4 }')
else
  plist=$(ps -eo pid=,ppid=,args= 2>/dev/null | awk '{ pid = $1; ppid = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); print pid "\t" ppid "\t" $0 }')
  me=$$
fi
running=$(procs_in_dir "$plist" "$here_path")
# At the session's end (Stop, not a subagent's, whose parent may be mid-command),
# every script this session started and left running counts too.
if [ "$(json_field "$input" hook_event_name)" = Stop ] && [ -n "$me" ]; then
  running="$running
$(session_procs "$plist" "$me")"
  # A script left behind by a shell that already ended has no living parent
  # to place it; its relative path, found under this folder, does.
  orphans=$(orphan_scripts "$plist" | while IFS="$(printf '\t')" read -r opid ocmd orel; do
    if [ -f "$orel" ]; then printf '%s\t%s\n' "$opid" "$ocmd"; fi
  done)
  running="$running
$orphans"
fi
running=$(printf '%s\n' "$running" | sed '/^$/d' | grep -v "	.*$$" | sort -u -t'	' -k1,1n | head -n 3)
if [ -n "$running" ]; then
  names=$(printf '%s\n' "$running" | awk -F'\t' '{ c = $2; if (length(c) > 60) c = substr(c, 1, 60) "..."; printf "%s (%s); ", $1, c }')
  problems="$problems Processes this session started are still running: $names stop them before finishing (TaskStop for a background task; a check that runs on is a bug to report, not to leave)."
fi

[ -n "$problems" ] || exit 0
printf '%s\n' "Not done yet, because a clean folder is part of done: $problems" >&2
exit 2
