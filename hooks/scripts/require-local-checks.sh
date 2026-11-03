#!/bin/sh
# PreToolUse hook for Bash: runs the quick checks before a push leaves the
# machine. On "git push" from a branch that is not main, it runs the
# project's scripts/ci/checks-local.sh (the cheap steps of CI's checks job)
# and refuses the push with the failures in the checks' own words. A size
# or mock failure is then fixed in seconds, not after a CI run, a cancel
# and a round trip. Quiet when the checks pass; does nothing in a project
# without the script, on main, or for a push that deletes a branch.
# Agents without hooks are held to the same rules by CI on the pull request.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"

input=$(cat)
cmd=$(json_field "$input" command)
[ -n "$cmd" ] || exit 0
case "$cmd" in *push*) ;; *) exit 0 ;; esac

# push_dir COMMAND: for a git push in COMMAND, the folder it runs in ("."
# when not named: a "cd DIR" before it, or "git -C DIR"); nothing when the
# command does not push, or only deletes or tags.
push_dir() {
  split_commands "$1" | awk '
    function unq(s) { gsub(/^["'"'"']|["'"'"']$/, "", s); return s }
    {
      n = split($0, w, /[ \t]+/)
      first = w[1]; sub(/.*[\/\\]/, "", first); sub(/\.exe$/, "", first)
      if (first == "cd" && n >= 2) { dir = unq(w[2]); next }
      if (first != "git") next
      d = dir; i = 2
      while (i <= n && w[i] ~ /^-/) {
        if (w[i] == "-C" && i < n) { d = unq(w[i + 1]); i += 2; continue }
        if (w[i] == "-c" && i < n) { i += 2; continue }
        i++
      }
      if (w[i] != "push") next
      for (j = i + 1; j <= n; j++)
        if (w[j] ~ /^(--delete|-d|--tags|--dry-run|-n|--mirror)$/ || w[j] ~ /^:/) next
      print (d == "" ? "." : d); exit
    }'
}

dir=$(push_dir "$cmd")
[ -n "$dir" ] || exit 0
cwd=$(json_field "$input" cwd)
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null
[ -d "$dir" ] && cd "$dir" 2>/dev/null || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$top/scripts/ci/checks-local.sh" ] || exit 0
branch=$(git symbolic-ref -q --short HEAD 2>/dev/null)
case "$branch" in ''|main|master) exit 0 ;; esac

out=$(cd "$top" && sh scripts/ci/checks-local.sh 2>&1) && exit 0

printf '%s\n' "Blocked the push because the quick checks CI runs on a pull request fail here, and would fail there too. Fix what they say, commit, and push again (sh scripts/ci/checks-local.sh runs them by hand):" >&2
printf '%s\n' "$out" >&2
exit 2
