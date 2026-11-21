#!/bin/sh
# What bounds a round (specs/023-drive-on-work): the builder's limit, never the runners that happen to be free. An agent does
# not use a runner while it works; it needs one when it pushes, and a round's
# pull requests land as one batch. Pure helpers; sourced by plan.sh and the
# plugin's tests.

# round_slots PER_ROUND MAX_AGENTS
# How many units a round may start: the units a round takes, within the limit
# the builder set (maxAgents), never below one. The health note is a
# recommendation to restart and never changes this.
round_slots() {
  rs_n=$1; [ "$2" -lt "$rs_n" ] && rs_n=$2
  [ "$rs_n" -ge 1 ] || rs_n=1
  echo "$rs_n"
}

# sized_words READY STARTED LIMIT ONLINE UNREAD
# What bounded the round, in plain words, for the "sized:" line: how many
# units were ready and free of conflict, how many started, what held the
# rest (the limit). When no build machine is online it says
# checks wait and the round starts anyway; when GitHub could not be read for
# some pull requests, that they are left out this round.
sized_words() {
  sw_s="$1 ready unit$([ "$1" = 1 ] || echo s) free of conflict, $2 started"
  if [ "$1" -gt "$2" ] 2>/dev/null; then
    sw_s="$sw_s; the limit of $3 agents a round held $(( $1 - $2 ))"
  fi
  [ "$4" = 0 ] && sw_s="$sw_s; no build machine is online, so checks wait until one is"
  [ "${5:-0}" -gt 0 ] 2>/dev/null && sw_s="$sw_s; GitHub could not be read for $5 pull request$([ "$5" = 1 ] || echo s), left out this round"
  printf '%s\n' "$sw_s"
}
