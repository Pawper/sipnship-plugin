#!/bin/sh
# Pure helpers for the runner watch's hourly record of the kernel's memory
# pools, so the trend can be shown and a level that slows builds is seen
# before an evening goes to it. Text in, text out.

# pool_record_due LAST NOW
# "yes" when the last record (an epoch, or empty for none) is an hour old
# less five minutes, or older; "no" otherwise. The watch runs every fifteen
# minutes, so the margin keeps one record an hour whatever the run's jitter.
pool_record_due() {
  case "$1" in
    ''|*[!0-9]*) echo yes; return 0 ;;
  esac
  if [ $(( $2 - $1 )) -ge 3300 ]; then echo yes; else echo no; fi
}

# pool_record NOW MEASURES
# One tab-separated line: NOW (epoch), uptime in hours, paged pool in GB,
# non-paged pool in GB, handles, processes. MEASURES is sample_measures'
# line (program start ms, uptime h, paged GB, non-paged GB, handles,
# processes, antivirus, old shells). Nothing when the system gave no paged
# pool reading, so a machine that cannot say records no empty rows.
pool_record() {
  printf '%s\n' "$2" | awk -F'\t' -v now="$1" '$3 != "" { printf "%s\t%s\t%s\t%s\t%s\t%s\n", now, $2, $3, $4, $5, $6 }'
}

# pool_record_keep FILE
# Thirty days of hourly records (720 lines) kept, the oldest dropped.
pool_record_keep() {
  [ -f "$1" ] || return 0
  tail -n 720 "$1" > "$1.new" 2>/dev/null && mv "$1.new" "$1"
}
