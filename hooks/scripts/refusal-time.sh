#!/bin/sh
# Pure helpers for the refusal logs: times and counts, never any text of a
# command. Sourced by refusal-log.sh and watch-resolution.sh.

# refusal_epoch ISO: seconds since 1970 for a UTC time like 2026-11-02T09:10:00Z
# (or a refusal's id, "time-process"); nothing when it is not one. Plain awk,
# so no date flag that differs between systems is needed.
refusal_epoch() {
  printf '%s' "$1" | awk -F'[-T:Z]' '
    $1 ~ /^[0-9][0-9][0-9][0-9]$/ && $2 ~ /^[0-9][0-9]$/ && $3 ~ /^[0-9][0-9]$/ && $4 ~ /^[0-9][0-9]$/ && $5 ~ /^[0-9][0-9]$/ && $6 ~ /^[0-9][0-9]$/ {
      y = $1 + 0; m = $2 + 0; d = $3 + 0
      if (m <= 2) y--
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      printf "%d\n", (era * 146097 + doe - 719468) * 86400 + $4 * 3600 + $5 * 60 + $6
    }'
}

# refusal_seconds FROM TO: whole seconds from one time to the other, never
# below 0; 0 when either is not a time.
refusal_seconds() {
  rs_a=$(refusal_epoch "$1"); rs_b=$(refusal_epoch "$2")
  if [ -z "$rs_a" ] || [ -z "$rs_b" ] || [ "$rs_b" -lt "$rs_a" ]; then echo 0; else echo $((rs_b - rs_a)); fi
}

# refusal_calls N: how many tool calls were made before a refusal settled, 0 to 5.
refusal_calls() {
  case "$1" in ''|*[!0-9]*) echo 0; return ;; esac
  if [ "$1" -gt 5 ]; then echo 5; else echo "$1"; fi
}

# refusal_via TOOL: the kind of tool that did a possible workaround, one of
# shell, file edit, agent, other. Never what the tool was given.
refusal_via() {
  case "$1" in
    Bash|PowerShell) echo shell ;;
    Edit|Write|MultiEdit|NotebookEdit) echo "file edit" ;;
    Agent|Task|Workflow) echo agent ;;
    *) echo other ;;
  esac
}
