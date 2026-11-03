#!/bin/sh
# The rescue alone, on a place that is up: the drain's step that starts
# again a build stuck on a machine that went offline (queue/rescue.sh). The
# drain on your machines runs it every round; this runs it from
# .github/workflows/place-rescue.yml on the first place in the order that is
# not your machines, so a machine that is off cannot hold up its own rescue.
#   env: GH_TOKEN, QUEUE_MERGE_TOKEN (the queue's identity, which can read
#        the runners and cancel and start runs), SIPNSHIP_PLACES,
#        SIPNSHIP_PLACE_REFUSED
# Bounded: one look, then up to three short checks that each cancelled run
# has ended and is started again; a run still ending is left to the next.
set -e
here=$(dirname "$0")
. "$here/batch-lib.sh"
. "$here/queue/state.sh"
. "$here/queue/rescue.sh"
log_file=/dev/null
round=1
drain_rescue
tries=0
while [ -n "$(printf '%s' "${rescue_pending:-}" | tr -d ' ')" ] && [ "$tries" -lt 3 ]; do
  tries=$((tries + 1))
  sleep 10
  rescue_finish
done
[ "$(rescue_on "${rescue_order:-}")" = yes ] || echo "The order has one place, or no wait limit; nothing to rescue."
