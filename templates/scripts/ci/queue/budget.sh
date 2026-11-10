#!/bin/sh
# The drain's time budget. Sourced with scripts/ci/queue/rules-drain.sh by
# batch-lib.sh; functions only.

# drain_over_budget START NOW MINUTES
# "yes" when a drain begun at START (epoch) has run MINUTES or more at NOW,
# so its end does only what is quick: the held steps, the unsticking and
# the re-read of failures are left to the next drain, which is short.
drain_over_budget() {
  if [ $(( $2 - $1 )) -ge $(( $3 * 60 )) ]; then echo yes; else echo no; fi
}
