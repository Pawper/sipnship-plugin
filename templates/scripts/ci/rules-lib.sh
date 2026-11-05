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
#                     when it is on, prints nothing and fails. On Actions it
#                     also leaves a notice titled "Rule off" whose message is
#                     the id, so the service keeps the step as off, not as a
#                     pass, though the step ends green.
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
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::notice title=Rule off::%s\n' "$1"; fi
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

# The sync and the person's own switch (scripts/ci/rules-sync.sh, and
# sh scripts/rules.sh off|on). Pure: they print, and touch nothing.
#   rules_ids_of          stdin to its ids, one per line, sorted: from the
#                         switches file (the first word of each line) or
#                         from RULES_OFF, one id to a line
#   rules_next_off CURRENT ID off|on
#                         the new RULES_OFF value: CURRENT with ID added or
#                         taken out, space-separated, sorted
#   rules_off_text IDS OLD DAY
#                         the switches file for the ids IDS (words); a rule
#                         already off in OLD keeps its day
#   rules_words ID        the rule in the builder's words, from the lists
#   rules_sync_title NOW WANT
#                         the plain title of the pull request that moves
#                         the off ids NOW to WANT (both lists of ids)
rules_ids_of() {
  tr -d '\r' | sed 's/#.*//' | awk 'NF { print $1 }' | sort -u
}

rules_next_off() {
  { printf '%s\n' "$1" | tr ' ' '\n' | awk -v id="$2" 'NF && $1 != id'; [ "$3" = off ] && printf '%s\n' "$2"; } | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

rules_off_text() {
  printf '%s\n' "# The rules that are off in this project, one 'ID YYYY-MM-DD' per line." \
    "# Written by the rule-switch sync from the repository variable RULES_OFF;" \
    "# change a switch on the Rules tab, never this file by hand."
  for ro_id in $1; do
    ro_day=$(printf '%s\n' "$2" | tr -d '\r' | sed 's/#.*//' | awk -v id="$ro_id" '$1 == id { print $2; exit }')
    printf '%s %s\n' "$ro_id" "${ro_day:-$3}"
  done
}

rules_words() {
  for rw_f in ${RULES_LISTS:-.claude/rules.txt .claude/rules-own.txt}; do
    [ -f "$rw_f" ] || continue
    tr -d '\r' < "$rw_f" | awk -v id="$1" '
      /^[ \t]*$/ { on = 0; next }
      /^id:/ { v = $0; sub(/^id:[ \t]*/, "", v); on = (v == id); next }
      on && /^words:/ { sub(/^words:[ \t]*/, ""); print; exit }'
  done | head -n 1
}

rules_sync_title() {
  rt_new=""; rt_gone=""
  for rt_i in $2; do case " $1 " in *" $rt_i "*) ;; *) rt_new="$rt_new $rt_i" ;; esac; done
  for rt_i in $1; do case " $2 " in *" $rt_i "*) ;; *) rt_gone="$rt_gone $rt_i" ;; esac; done
  # shellcheck disable=SC2086
  set -- $rt_new $rt_gone
  if [ "$#" = 1 ]; then
    if [ -n "$rt_new" ]; then rt_st=off; else rt_st=on; fi
    rt_w=$(rules_words "$1"); rt_w=${rt_w:-$1}
    printf 'Your rules: %s is %s\n' "$rt_w" "$rt_st"
  else
    printf 'Your rules: %s switches changed\n' "$#"
  fi
}
