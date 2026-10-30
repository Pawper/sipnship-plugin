#!/bin/sh
# A small suite shaped like tests/run.sh, for the rooftop-garden app:
# a prelude, four blocks (one of the queue's, one console) and the summary.
. "$PARTS_LIB"
pass=0
fail=0
fail_fast=${FAIL_FAST:-no}
eq() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$1"
    block_failed "FAIL  $1"
  fi
}

section 'garden beds'
eq "a bed has a name" "tomatoes" "tomatoes"

section 'watering schedule'
eq "the morning round waters the herbs" "herbs" "mint"
eq "the evening round is after six" "18" "18"

section 'drain'
eq "the queue drains" "yes" "yes"

section 'owner console (node)'
eq "the console opens" "yes" "yes"

# --- end of blocks: the summary, kept in every part.
stop_if_red
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
