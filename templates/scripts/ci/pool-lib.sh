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

# pool_record NOW MEASURES RUNS SESSIONS
# One tab-separated line: NOW (epoch), uptime in hours, paged pool in GB,
# non-paged pool in GB, handles, processes, CI runs and agent sessions
# since the last record (RUNS, SESSIONS; empty, or left out, counts as 0,
# so an older caller still writes a row). MEASURES is sample_measures'
# line (program start ms, uptime h, paged GB, non-paged GB, handles,
# processes, antivirus, old shells). Nothing when the system gave no paged
# pool reading, so a machine that cannot say records no empty rows. The
# two added fields let growth be read per run, not only per hour (#1543).
pool_record() {
  pr_runs=$3; pr_sessions=$4
  case "$pr_runs" in ''|*[!0-9]*) pr_runs=0 ;; esac
  case "$pr_sessions" in ''|*[!0-9]*) pr_sessions=0 ;; esac
  printf '%s\n' "$2" | awk -F'\t' -v now="$1" -v runs="$pr_runs" -v sessions="$pr_sessions" '$3 != "" { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", now, $2, $3, $4, $5, $6, runs, sessions }'
}

# ci_runs_since RUNS SINCE
# How many of RUNS (the runner watch's own "runs" tsv: id, name, branch,
# status, created epoch, started epoch) have a created epoch after
# SINCE; every one fetched when SINCE is empty, since there is no
# earlier pool record yet to compare against.
ci_runs_since() {
  printf '%s\n' "$1" | awk -F'\t' -v since="$2" '
    NF < 5 { next }
    since == "" || $5 + 0 > since + 0 { n++ }
    END { print n + 0 }
  '
}

# pool_record_keep FILE
# Thirty days of hourly records (720 lines) kept, the oldest dropped.
pool_record_keep() {
  [ -f "$1" ] || return 0
  tail -n 720 "$1" > "$1.new" 2>/dev/null && mv "$1.new" "$1"
}

# probe_quiet_update NOW QUIET
# NOW is sample_measures' own program-start reading, in milliseconds;
# QUIET the lowest the watch has seen on this machine, or empty for none
# yet. Print the lower of the two (NOW, the first time there is no QUIET).
# Kept across runs so a slow start is told from this machine's own quiet
# one, never a fixed number. Mirrors the session brief's probe_quiet
# (plugin/hooks/scripts/session-brief-probe.sh): the two keep their own
# reading apart (a session's start against a scheduled task's), but the
# shape and the wording below match, so a builder reads the same
# recommendation whichever reaches them first.
probe_quiet_update() {
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2"; return 0 ;; esac
  case "$2" in ''|*[!0-9]*) printf '%s\n' "$1"; return 0 ;; esac
  if [ "$1" -lt "$2" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# probe_verdict NOW QUIET
# "slow-start|sentence" when NOW takes at least 30 ms and over twice QUIET
# (and at least 30, so a few milliseconds of jitter is not news); nothing
# otherwise, including while QUIET is still empty (no baseline yet). Feeds
# load_verdicts' own "id|sentence" shape, so watch_changes says it once,
# when it starts and when it ends, and nothing here ever gates a build:
# time is a metric, not a gate (#1803).
probe_verdict() {
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  [ "$1" -ge 30 ] && [ "$1" -gt $(( 2 * $2 )) ] || return 0
  printf 'slow-start|a program now takes %s ms to start, over twice this machine'"'"'s quiet reading of %s ms. Recommended: let the agents and local test runs finish before starting more; if it stays slow with the machine quiet, restart it. A recommendation only, nothing is paused.\n' "$1" "$2"
}
