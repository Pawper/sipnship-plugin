#!/bin/sh
# Sourced by each check script, first. Each rule has a switch:
# .claude/rules-off.txt lists the ids of the rules that are off, one
# "ID YYYY-MM-DD" per line, and the hooks, the checks and the table in
# AGENTS.md all read that one file from the same checkout, so they change
# together. Run from the project's root, as CI and checks-local.sh do;
# RULES_OFF_FILE names another file (the tests use it).
#
#   rule_off_day ID   succeeds when the rule is off, printing the day it
#                     went off as "YYYY-MM-DD" (nothing when no day is
#                     given). A missing or unreadable file means every rule
#                     is on.
#   rule_skip ID      for a check: when its rule is off, prints the one
#                     plain line and succeeds, and the check ends with 0;
#                     when it is on, prints nothing and fails.
#   rules_locked      the ids of the locked rules, one per line, from the
#                     project's two lists.
rule_off_day() {
  rf_f=${RULES_OFF_FILE:-.claude/rules-off.txt}
  [ -f "$rf_f" ] && [ -r "$rf_f" ] || return 1
  tr -d '\r' < "$rf_f" 2>/dev/null | sed 's/#.*//' | awk -v id="$1" '$1 == id { print $2; f = 1; exit } END { exit f ? 0 : 1 }'
}

rule_skip() {
  rs_day=$(rule_off_day "$1") || return 1
  rs_when=""
  if [ -n "$rs_day" ]; then
    rs_when=$(printf '%s\n' "$rs_day" | awk -F- 'NF == 3 && $2 + 0 >= 1 && $2 + 0 <= 12 {
      split("January February March April May June July August September October November December", m, " ")
      printf " since %s %d, %s", m[$2 + 0], $3 + 0, $1 }')
  fi
  printf 'This rule is off in this project%s; nothing was checked.\n' "$rs_when"
}

rules_locked() {
  for rl_f in ${RULES_LISTS:-.claude/rules.txt .claude/rules-own.txt}; do
    [ -f "$rl_f" ] || continue
    tr -d '\r' < "$rl_f" | awk '
      function flush() { if (id != "" && locked == "yes") print id; id = ""; locked = "" }
      /^[ \t]*$/ { flush(); next }
      /^id:/ { sub(/^id:[ \t]*/, ""); id = $0; next }
      /^locked:/ { sub(/^locked:[ \t]*/, ""); locked = $0 }
      END { flush() }'
  done
}
