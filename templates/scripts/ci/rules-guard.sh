#!/bin/sh
# The two guards on the rule switches, a step of the checks job beside
# "sh scripts/rules.sh check". They bite only when a pull request changes
# .claude/rules-off.txt; leaving the file alone never fails, so a switch
# flipped while its sync is still pending never turns other work red.
#   1. the new file must name exactly the rules in the variable RULES_OFF
#      (space-separated ids), the one the app set: an agent cannot switch a
#      rule off by editing the file.
#   2. a locked rule may go off only while RULES_LOCKS is "released".
# RULES_OFF and RULES_LOCKS come from the repository's variables. Where the
# variables are not in the environment at all (checks-local.sh on a
# machine), the guards are CI's to hold and are skipped there.
# Usage: sh scripts/ci/rules-guard.sh BASE HEAD
. "$(dirname "$0")/rules-lib.sh"
base=${1:?usage: rules-guard.sh BASE HEAD}
head=${2:?usage: rules-guard.sh BASE HEAD}
file=.claude/rules-off.txt

ids_of() { tr -d '\r' | sed 's/#.*//' | awk 'NF { print $1 }' | sort -u; }
base_ids=$(git show "$base:$file" 2>/dev/null | ids_of)
head_ids=$(git show "$head:$file" 2>/dev/null | ids_of)
if [ "$base_ids" = "$head_ids" ] && [ "$(git show "$base:$file" 2>/dev/null)" = "$(git show "$head:$file" 2>/dev/null)" ]; then
  echo "The rule switches are unchanged."
  exit 0
fi
if [ -z "${RULES_OFF+x}" ] && [ -z "${RULES_LOCKS+x}" ]; then
  echo "The rule switches changed; the variables are read in CI, so they are checked there."
  exit 0
fi

want=$(printf '%s\n' ${RULES_OFF:-} | awk 'NF' | sort -u)
if [ "$head_ids" != "$want" ]; then
  echo "This change edits the rule switches (.claude/rules-off.txt) so that they differ from the ones set in the app (${RULES_OFF:-none off}). A switch is turned on the Rules tab, never by editing the file; the sync writes the file itself." >&2
  exit 1
fi

newly=$(printf '%s\n' "$head_ids" | awk 'NF' | grep -vxF "$base_ids" || true)
locked=$(rules_locked)
bad=""
for id in $newly; do
  printf '%s\n' "$locked" | grep -qxF "$id" && bad="$bad $id"
done
if [ -n "$bad" ] && [ "${RULES_LOCKS:-}" != released ]; then
  echo "This change turns off a locked rule ($(printf '%s' "$bad" | sed 's/^ //; s/ /, /g')) while the safety locks are on. Those rules protect work that cannot be brought back; release the safety locks in Settings first." >&2
  exit 1
fi
echo "The rule switches match the ones set in the app."
