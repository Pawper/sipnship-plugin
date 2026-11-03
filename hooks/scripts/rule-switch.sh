#!/bin/sh
# Sourced by each rule hook, after lib.sh and refusal-log.sh. Each rule has
# a switch: .claude/rules-off.txt in the project lists the ids of the rules
# that are off, one "ID YYYY-MM-DD" per line. The hook, the CI step and the
# row in AGENTS.md all read that one file from the same checkout, so they
# change together (specs/016-rule-switches).
#
#   rule_on ID     succeeds when the rule is on. A missing or unreadable
#                  file means on; only a line naming the id turns it off.
#   rule_gate ID   for a hook that has found something to refuse: when the
#                  rule is on it returns and the hook refuses as always;
#                  when it is off it notes that it let the call through,
#                  and ends the hook with exit 0.
#
# The note is one line in .scratch/hooks-off.log (time, hook, rule id,
# session), never the command, so the builder can see what a switch cost.
# HOOK_LOG=0 turns it off, as for refusals. The file is read from
# RULES_OFF_FILE when set (the tests use it), else from the project.
rule_on() {
  ro_f=${RULES_OFF_FILE:-${CLAUDE_PROJECT_DIR:-.}/.claude/rules-off.txt}
  [ -f "$ro_f" ] && [ -r "$ro_f" ] || return 0
  tr -d '\r' < "$ro_f" 2>/dev/null | sed 's/#.*//' | awk -v id="$1" '$1 == id { f = 1 } END { exit f ? 0 : 1 }' && return 1
  return 0
}

rule_off_note() {
  [ "${HOOK_LOG:-1}" != 0 ] || return 0
  ro_s=$(refusal_log_dir) || return 0
  mkdir -p "$ro_s" 2>/dev/null || return 0
  ro_sess=$(json_field "${input:-}" session_id 2>/dev/null)
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0" .sh)" "$1" "${ro_sess:-unknown}" >> "$ro_s/hooks-off.log" 2>/dev/null || true
}

rule_gate() {
  rule_on "$1" && return 0
  rule_off_note "$1"
  exit 0
}

# rule_switch_reason COMMAND
# Print what a command does to the switches themselves: it sets or deletes
# the repository variable RULES_OFF or RULES_LOCKS (gh variable, or the REST
# form of gh api that writes), writes .claude/rules-off.txt, or runs the
# person's own switch (sh scripts/rules.sh off|on). Print nothing for a read.
rule_switch_reason() {
  split_commands "$1" | awk '
    {
      line = $0
      gsub(/["'\'']/, "", line)
      n = split(line, t, /[ \t]+/)
      first = t[1]; sub(/.*[\/\\]/, "", first); sub(/\.exe$/, "", first)
      vars = (line ~ /(^|[^A-Za-z_])RULES_(OFF|LOCKS)([^A-Za-z_]|$)/)
      if (first == "gh" && t[2] == "variable" && vars && t[3] ~ /^(set|delete|remove)$/) { print "gh variable " t[3] " RULES_*"; exit }
      if (first == "gh" && t[2] == "api" && vars && line ~ /variables/) {
        write = 0
        for (i = 3; i <= n; i++) {
          if ((t[i] == "-X" || t[i] == "--method") && toupper(t[i + 1]) != "GET") write = 1
          if (t[i] ~ /^--method=/ && toupper(substr(t[i], 10)) != "GET") write = 1
          if (t[i] ~ /^-f|^-F|^--field|^--raw-field|^--input/) write = 1
        }
        if (write) { print "gh api (writing RULES_*)"; exit }
      }
      if (line ~ /rules-off\.txt/) {
        edits = (first ~ /^(tee|mv|cp|install|truncate|ln|rm)$/) || (first ~ /^(sed|perl)$/ && line ~ / -[a-zA-Z]*i/)
        if (line ~ />/ || edits) { print ".claude/rules-off.txt"; exit }
      }
      for (i = 1; i < n; i++)
        if (t[i] ~ /(^|[\/\\])rules\.sh$/ && t[i + 1] ~ /^(on|off)$/) { print "scripts/rules.sh " t[i + 1]; exit }
    }'
}

# rule_switch_path_reason PATH
# Print the path when it is the switches file, the one an edit may not touch.
rule_switch_path_reason() {
  rs_p=$(printf '%s' "$1" | tr '\\' '/')
  case "${rs_p##*/}" in rules-off.txt) printf '%s\n' "$rs_p" ;; esac
}
