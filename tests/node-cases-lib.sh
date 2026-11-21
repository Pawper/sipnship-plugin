#!/bin/sh
# node_cases SAY FILE PATTERN
# Runs the cases of one node:test FILE whose names match PATTERN, as one line
# of the block that sources this: "ok SAY (N cases)" when none failed, else a
# FAIL with the failing cases named. A machine without node skips it.
node_cases() {
  if ! command -v node >/dev/null 2>&1; then printf 'skip  node is not on this machine\n'; return 0; fi
  nc_out=$(node --test --test-reporter tap --test-name-pattern "$3" "$2" 2>&1)
  nc_fail=$(printf '%s\n' "$nc_out" | sed -n 's/^# fail \([0-9]*\).*/\1/p' | tr -d '\r')
  nc_pass=$(printf '%s\n' "$nc_out" | sed -n 's/^# pass \([0-9]*\).*/\1/p' | tr -d '\r')
  eq "$1 (${nc_pass:-0} cases)" "0" "${nc_fail:-1}"
  [ "${nc_fail:-1}" = 0 ] || printf '%s\n' "$nc_out" | grep -E '^not ok' | head -n 10
  return 0
}
