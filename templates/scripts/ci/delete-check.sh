#!/bin/sh
# Fail when a change deletes a tracked file outright. The rule is never
# delete; move aside. A move is not a delete (renames are detected), the
# pages listed in .claude/generated-pages.txt and anything under .scratch/
# never count, and a pull request that must delete says why in a line of its
# body, written exactly: "Deletes: <reason>" (read from PR_BODY).
# Usage: PR_BODY="..." sh scripts/ci/delete-check.sh BASE HEAD
base=${1:?usage: delete-check.sh BASE HEAD}
head=${2:?usage: delete-check.sh BASE HEAD}

raw=$(git diff --name-status -M --diff-filter=D "$base" "$head") || { echo "Could not read the diff between $base and $head; the checkout may be shallow (use fetch-depth: 0). This is not a deleted file." >&2; exit 1; }
gone=$(printf '%s\n' "$raw" | sed -n 's/^D[[:space:]][[:space:]]*//p' | grep -v '^\.scratch/' || true)
if [ -f .claude/generated-pages.txt ]; then
  gen=$(sed 's/#.*//; s/[[:space:]]*$//; /^[[:space:]]*$/d' .claude/generated-pages.txt)
  [ -z "$gen" ] || gone=$(printf '%s\n' "$gone" | grep -vxF "$gen" || true)
fi
[ -n "$gone" ] || { echo "Delete check passed."; exit 0; }

if printf '%s\n' "${PR_BODY:-}" | tr -d '\r' | grep -Eq '^Deletes: *[^ ]'; then
  echo "Delete check passed: the pull request gives a reason (Deletes:)."
  exit 0
fi
echo "This change deletes: $(printf '%s' "$gone" | paste -sd' ' - | sed 's/ /, /g'). This project never deletes; move files aside instead. If a deletion is truly needed, add a line to the pull request body, written exactly so: Deletes: <reason>" >&2
exit 1
