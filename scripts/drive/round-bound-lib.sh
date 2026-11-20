#!/bin/sh
# What bounds a round (specs/023-drive-on-work): the builder's limit and the
# computer's own load, never the runners that happen to be free. An agent does
# not use a runner while it works; it needs one when it pushes, and a round's
# pull requests land as one batch. Pure helpers; sourced by plan.sh and the
# plugin's tests.

# computer_busy VALUE ABOVE
# "yes" when the figure the drive already reads for its health line (program
# start time or memory) is over the limit the builder set for it; "no" when
# it is not, when there is no limit, or when it could not be read.
computer_busy() {
  case "$1" in ''|*[!0-9.]*) echo no; return 0 ;; esac
  [ -n "$2" ] || { echo no; return 0; }
  awk -v v="$1" -v a="$2" 'BEGIN { print ((v + 0 > a + 0) ? "yes" : "no") }'
}

# round_slots PER_ROUND MAX_AGENTS BUSY
# How many units a round may start: the units a round takes, within the limit
# the builder set (maxAgents); a busy computer halves it, never below one.
round_slots() {
  rs_n=$1; [ "$2" -lt "$rs_n" ] && rs_n=$2
  [ "$3" = yes ] && rs_n=$(( (rs_n + 1) / 2 ))
  [ "$rs_n" -ge 1 ] || rs_n=1
  echo "$rs_n"
}

# sized_words READY STARTED LIMIT BUSY ONLINE UNREAD
# What bounded the round, in plain words, for the "sized:" line: how many
# units were ready and free of conflict, how many started, what held the
# rest (the limit, or the computer). When no build machine is online it says
# checks wait and the round starts anyway; when GitHub could not be read for
# some pull requests, that they are left out this round.
sized_words() {
  sw_s="$1 ready unit$([ "$1" = 1 ] || echo s) free of conflict, $2 started"
  if [ "$1" -gt "$2" ] 2>/dev/null; then
    if [ "$4" = yes ]; then sw_s="$sw_s; your computer is busy, so $(( $1 - $2 )) start when it has room"
    else sw_s="$sw_s; the limit of $3 agents a round held $(( $1 - $2 ))"; fi
  fi
  [ "$5" = 0 ] && sw_s="$sw_s; no build machine is online, so checks wait until one is"
  [ "${6:-0}" -gt 0 ] 2>/dev/null && sw_s="$sw_s; GitHub could not be read for $6 pull request$([ "$6" = 1 ] || echo s), left out this round"
  printf '%s\n' "$sw_s"
}
