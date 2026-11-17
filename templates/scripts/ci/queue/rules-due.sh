#!/bin/sh
# Pure rules for the way back after a drain stopped short. Loaded by
# scripts/ci/batch-lib.sh; nothing here calls git or gh.
#
# A drain on a runner ends at every hold and starts again when a pull
# request's checks finish, so a drain that was killed (a restart), a hold
# that ran out with nothing running, or a round-mate that went red could each
# leave a green change waiting until the two-hourly run. The frequent
# schedule in queue-drain.yml asks drain_due_reason, from facts read with
# scripts/ci/queue/due.sh, whether a drain is owed, and starts one when it is.

# drain_due_reason FACTS: why a drain is owed now, in one plain line, or
# nothing. FACTS is one line of tab-separated numbers and words:
#   LOCK    yes when the queue's lock is still held on GitHub
#   ACTIVE  how many drains are queued or running right now
#   LAST    how the last finished drain ended (success, failure, cancelled,
#           timed_out), nothing when none is known
#   AGE     seconds since that drain finished
#   MODE    the published state's mode (idle, drain, ...), nothing if unknown
#   HOLD    the epoch a published hold ends at the latest, 0 when none
#   GREEN   how many open changes the published state calls green
#   SINCE   seconds since the state was last published
#   NOW     the epoch now
# A failed last drain is not a reason in itself: a drain exits non-zero to
# name what needs attention, and starting another each time would never end.
# The green wait is QUEUE_DUE_GREEN_MINUTES (default 20); a drain that ended
# without finishing is acted on for QUEUE_DUE_WINDOW_MINUTES (default 120).
drain_due_reason() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v greenmin="${QUEUE_DUE_GREEN_MINUTES:-20}" -v window="${QUEUE_DUE_WINDOW_MINUTES:-120}" '
    NR == 1 {
      lock = $1; active = $2 + 0; last = $3; age = $4 + 0; mode = $5; hold = $6 + 0; green = $7 + 0; since = $8 + 0; now = $9 + 0
      if (active > 0) exit
      if (lock == "yes") { print "a drain ended without finishing and left the queue locked"; exit }
      if ((last == "cancelled" || last == "timed_out") && age <= window * 60) { print "the last drain was stopped before it finished"; exit }
      if (mode == "drain") exit
      if (hold > 0 && hold <= now) { print "a hold ran out and nothing started the drain that lands the change"; exit }
      if (green > 0 && hold <= now && since >= greenmin * 60) { printf "%d change(s) have been green for %d minutes with nothing running\n", green, int(since / 60); exit }
    }'
}

# drain_due_hold BODY: the latest end of a published hold, as the epoch, 0
# when the state carries none. BODY is the Merge queue issue's text.
drain_due_hold() {
  dh_t=$(printf '%s' "$1" | tr -d '\r' | grep -o '"endsAt":"[^"]*"' | head -n 1 | sed 's/.*:"\(.*\)"/\1/')
  [ -n "$dh_t" ] || { echo 0; return 0; }
  date -u -d "$dh_t" +%s 2>/dev/null || echo 0
}

# drain_due_green BODY: how many open changes the published state calls
# green (the "open" list only, never the main branch's own state).
drain_due_green() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/.*"open":\[//; s/\],"checking".*//' | grep -o '"state":"green"' | wc -l | tr -d ' '
}
