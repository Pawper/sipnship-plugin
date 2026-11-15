#!/bin/sh
# Words the plan puts on a red pull request's line: the clock time of its last
# push and the reds a set-aside counted. Functions only; sourced by plan.sh.

# clock_of EPOCH: the local clock time ("11:13 AM") of an epoch second, or nothing.
clock_of() {
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  date -d "@$1" +'%I:%M %p' 2>/dev/null | sed 's/^0//' || date -r "$1" +'%I:%M %p' 2>/dev/null | sed 's/^0//'
}

# reds_words SHAS MAIN_COUNT
# SHAS is one failed commit per line (repeats allowed); MAIN_COUNT how many reds were
# main's own and so left out of the count. "red on commits abc1234, def5678; 1 red from main left out",
# so a person can see which reds a set-aside counted; nothing when there is no commit.
reds_words() {
  rw_c=$(printf '%s\n' "$1" | awk 'NF && !s[$1]++ { printf "%s%s", (n++ ? ", " : ""), substr($1, 1, 7); k++ } END { if (k) printf "\t%d", k }')
  [ -n "$rw_c" ] || return 0
  rw_n=${rw_c##*	}; rw_s=${rw_c%	*}
  rw_t="red on commit"; [ "$rw_n" -gt 1 ] && rw_t="red on commits"
  rw_m=""
  if [ "${2:-0}" -gt 0 ] 2>/dev/null; then rw_m="; $2 red"; [ "$2" -gt 1 ] && rw_m="${rw_m}s"; rw_m="$rw_m from main left out"; fi
  printf '%s %s%s\n' "$rw_t" "$rw_s" "$rw_m"
}
