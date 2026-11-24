#!/bin/sh
# No shell loop ends on a bare "[ test ] && cmd": it returns 1 when the test is
# false, and inside $(...) under set -e that ends the script without a word
# (worktrees.sh close, --serial and the hold scan each did). The plugin's own
# suite holds the same rule; this runs on the pull request, so a change made
# after an agent's last suite run is still caught before the batch.
# Usage: sh scripts/ci/loop-tail-check.sh. Prints "file:line" for each; exit 1.
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$top" || exit 1
bad=$(for f in $(git ls-files '*.sh' | grep -v '^plugin/tests/'); do
  awk -v f="$f" '{ l[NR] = $0 } END { for (i = 1; i <= NR; i++) { if (l[i] !~ /\][ \t]*&&/ || l[i] ~ /\|\|/) continue; j = i + 1; while (j <= NR && l[j] ~ /^[ \t]*(#.*)?$/) j++; if (j <= NR && l[j] ~ /^[ \t]*done/) printf "%s:%d\n", f, i } }' "$f"
done)
one=$(git ls-files '*.sh' | grep -v '^plugin/tests/' | xargs grep -nE 'do .*\] *&& [^|]*; *done' 2>/dev/null | grep -v '||' | cut -d: -f1,2)
all=$(printf '%s\n%s\n' "$bad" "$one" | sed '/^$/d')
if [ -n "$all" ]; then
  echo "A shell loop ends on a bare test, so it returns 1 when the test is false and set -e ends the script without a word. End it on an if, or add || true:"
  printf '%s\n' "$all" | sed 's/^/  /'
  exit 1
fi
exit 0
