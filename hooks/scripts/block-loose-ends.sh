#!/bin/sh
# PreToolUse hook for Bash: refuses two ways of leaving work with no ending.
#   - gh pr close with no comment: a closed pull request must say why, or
#     what replaced it.
#   - git worktree add --detach: commits made on a detached HEAD are
#     reachable only from that folder; always create a branch.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"
. "$here/worktree-lib.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0
desc=$(json_field "$input" description)

long_hit=$(long_command_reason "$cmd" "$desc")
case "$long_hit" in
  "") ;;
  "no description")
    printf '%s\n' "Blocked a Bash call with no description: the task window shows the raw command instead of a title. The command itself is fine; call it again with the Bash tool's \`description\` field set to a few words saying what it does." >&2
    exit 2 ;;
  *)
    printf '%s\n' "Blocked a Bash call of $long_hit of code (quoted text is not counted), because a program pasted into the command fills the task window with its source and has no name; write it to .scratch/NAME.sh (or .py) with the Write tool, run it as \`sh .scratch/NAME.sh\`, and give the call a one-line description. A long pull request or issue body goes in a file: \`-F body=@.scratch/body.md\`." >&2
    exit 2 ;;
esac

if [ -n "$(pr_close_reason "$cmd")" ]; then
  printf '%s\n' "Blocked \`gh pr close\` because a closed pull request needs an ending; add \`--comment\` saying why or what replaced it, or run \`sh scripts/worktrees.sh close PR \"reason\"\`, which also archives the branch and removes its worktree." >&2
  exit 2
fi
wait_hit=$(stdin_wait_reason "$cmd")
if [ -n "$wait_hit" ]; then
  printf '%s\n' "Blocked \`$wait_hit\` because it reads input that never comes and would hang the shell; give it a file to read, pipe something into it, or use a heredoc (\`cat > file <<'EOF'\`)." >&2
  exit 2
fi
if [ -n "$(worktree_add_reason "$cmd")" ]; then
  printf '%s\n' "Blocked a detached worktree because its commits would be reachable only from that folder; add it with a branch instead, for example \`git worktree add -b task-name path\`." >&2
  exit 2
fi
daemon_hit=$(daemon_stop_reason "$cmd")
if [ -n "$daemon_hit" ]; then
  printf '%s\n' "Blocked \`$daemon_hit\` because the build daemon is shared by every build on this machine, including a self-hosted runner's job in flight, which fails with \"daemon has been stopped\". Let it idle out; stopping what you started means your own servers and watchers, not the daemon. If no runner runs on this machine, prefix the command with DAEMON_STOP_OK=1." >&2
  exit 2
fi
exit 0
