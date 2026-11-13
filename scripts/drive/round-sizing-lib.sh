#!/bin/sh
# How the drive sizes a round and says why a unit waited: the agents the
# machines allow, and the hold lines for deferred units. Pure helpers, text
# in and text out; split from round-lib.sh to keep it under its size limit.
# Functions only; sourced by plan.sh after round-lib.sh, and by tests/run.sh.

# agent_runners LISTING [CAP]
# How many agents may work at once, from the machines GitHub lists: LISTING
# is one "STATUS<TAB>BUSY(true|false)" line per registered runner. The count
# is the runners online and not busy, less one kept for the queue and its
# checks (never below one while any is free); CAP, when above 0, is the most
# the project's config allows. Prints "AGENTS<TAB>ONLINE<TAB>FREE", or
# nothing when GitHub listed no runner (the caller falls back to the config).
agent_runners() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v cap="${2:-0}" '
    NF >= 2 { seen++; if ($1 == "online") { online++; if ($2 != "true") free++ } }
    END {
      if (!seen) exit
      a = free - 1; if (free > 0 && a < 1) a = 1; if (a < 0) a = 0
      if (cap + 0 > 0 && a > cap + 0) a = cap + 0
      printf "%d\t%d\t%d\n", a, online + 0, free + 0
    }'
}

# agent_runners_say LINE [CAP]
# LINE is agent_runners' output: the plan's heading words, naming the number
# used and where it came from ("5 runners online, 4 free for agents").
agent_runners_say() {
  printf '%s\n' "$1" | awk -F'\t' -v cap="${2:-0}" '
    NF >= 3 {
      s = $2 " runner" ($2 == 1 ? "" : "s") " online, " $1 " free for agents"
      if (cap + 0 > 0 && $3 - 1 > cap + 0) s = s " (the config caps it at " cap ")"
      print s
    }'
}

# deferred_holds ROUND
# ROUND is the plan's lines. For the plan's "defer N unit(s): ... (#5, #6 #7)"
# line, print the round file's lines for the units it left out, one
# "hold: 5 | why: No free runner this round" each, so the Work tab says
# why a unit is not in the round instead of saying nothing. A unit with
# several issues is one hold line naming all of them.
#
# deferred_holds ROUND RUNNING ISSUE_AREAS: RUNNING (running_units' lines,
# "ISSUES<TAB>AREAS", commas) and ISSUE_AREAS ("NUMBER<TAB>AREAS" lines) let a
# deferred unit in an area a running unit owns wait on that unit instead:
# "hold: 5 | after: 12 14 | why: ...", since publish-round.sh refuses it as a
# unit in the running unit's area. Both are optional.
deferred_holds() {
  printf '%s\n' "$1" | awk -v running="${2:-}" -v ia="${3:-}" '
    BEGIN {
      n = split(running, rl, "\n"); for (i = 1; i <= n; i++) if (rl[i] != "") { split(rl[i], f, "\t"); nr++; rs[nr] = f[1]; ra[nr] = f[2] }
      n = split(ia, il, "\n"); for (i = 1; i <= n; i++) if (il[i] != "") { split(il[i], f, "\t"); iarea[f[1]] = f[2] }
    }
    /^defer [0-9]+ unit\(s\):/ {
      s = $0; i = match(s, /\(#[^)]*\)$/); if (!i) next
      s = substr(s, RSTART + 1, RLENGTH - 2)
      n = split(s, pieces, /, /)
      for (k = 1; k <= n; k++) {
        p = pieces[k]; gsub(/#/, "", p)
        split(p, first, " "); hit = ""; who = ""; mine = iarea[first[1]]
        if (mine != "") for (q = 1; q <= nr && hit == ""; q++) {
          na = split(mine, ma, ","); nb = split(ra[q], mb, ",")
          for (x = 1; x <= na && hit == ""; x++) for (y = 1; y <= nb; y++) if (ma[x] != "" && ma[x] == mb[y]) { hit = ma[x]; who = rs[q] }
        }
        if (hit != "") { gsub(/,/, " ", who); print "hold: " p " | after: " who " | why: Its area, " hit ", is owned by the running unit" }
        else print "hold: " p " | why: No free runner this round"
      }
    }'
}

# sized_line SAID: the round file's line for how the plan sized the round,
# from the plan's own words ("5 runners online, 4 free for agents"); empty
# when it said nothing. The Work tab's "Why this many" tip reads it.
sized_line() {
  [ -n "$1" ] || return 0
  printf 'sized: %s\n' "$(printf '%s' "$1" | tr -d '\r' | cut -c1-160)"
}
