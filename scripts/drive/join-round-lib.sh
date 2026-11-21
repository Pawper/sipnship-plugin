#!/bin/sh
# A running round takes new units (#2122). One round still lands as one batch,
# but a proposed unit that conflicts with no unit running in it starts at once,
# as a unit of that round, whether it was asked for or not; one that shares an
# area with a running unit waits for that unit alone. Pure helpers, text in and
# text out; tests/run.sh covers each. Sourced by approval.sh.

# proposed_units COMMENTS
# The units of the latest proposed round published on the drive issue (its
# sipnship-proposal marker with status proposed), one "ISSUES<TAB>AREAS" line
# each, both comma separated. Nothing when there is none.
proposed_units() {
  printf '%s\n' "$1" | tr -d '\r' | grep -F 'sipnship-proposal {"status":"proposed"' | tail -n 1 \
    | sed 's/.*sipnship-proposal {"status":"proposed",//; s/"held":.*//' | awk '
      {
        k = split($0, part, /\{"issues":/)
        for (p = 2; p <= k; p++) {
          u = part[p]
          if (!match(u, /^\[[0-9, ]*\]/)) continue
          is = substr(u, 2, RLENGTH - 2); gsub(/ /, "", is)
          ar = ""
          if (match(u, /"areas":\[[^]]*\]/)) { ar = substr(u, RSTART + 9, RLENGTH - 10); gsub(/"/, "", ar) }
          if (is != "") print is "\t" ar
        }
      }'
}

# keep_running_units ROUND RUNNING
# ROUND is the round file's text (as round_areas printed it); RUNNING running_units'
# lines with the pull request as a third column ("ISSUES<TAB>AREAS<TAB>PR"). The
# round with a "unit:" line added for each running unit that none of its lines
# names, so a started round published while another runs holds both: one round,
# its running units kept beside the added ones.
keep_running_units() {
  printf '%s\n' "$1"
  printf '%s\n' "$2" | tr -d '\r' | awk -F'\t' -v round="$(printf '%s\n' "$1" | tr -d '\r' | grep -E '^[ 	]*(unit|hold|apart):' | sed 's/^[^:]*://; s/|.*//' | tr -d ',#' | tr '\n' ' ')" '
    BEGIN { n = split(round, a, " "); for (i = 1; i <= n; i++) named[a[i]] = 1 }
    $1 != "" {
      k = split($1, t, ","); hit = 0; for (i = 1; i <= k; i++) if (t[i] in named) hit = 1
      if (hit) next
      iss = $1; gsub(/,/, " ", iss); ar = $2; gsub(/,/, ", ", ar)
      print "unit: " iss " | areas: " ar ($3 != "" ? " | pr: " $3 : "")
    }'
}

# join_dispatch GOALS RUNNING RUN_UNITS PROPOSED
# GOALS are the approved goals; RUNNING the issues of the running round (space
# separated); RUN_UNITS running_units' lines (the units still at work, with their
# areas); PROPOSED proposed_units' lines. A dispatch goal goes ahead, joining the
# running round, when its unit shares no area with any running unit and names no
# issue already running; a unit whose areas are unknown waits, since nothing shows
# it is free. A goal that went First goes ahead as before. Every other goal goes
# ahead. Prints the goals left, then one "held:" line when a dispatch waited.
# Without PROPOSED (no round on the tab to read areas from) every dispatch waits,
# as hold_dispatch says.
join_dispatch() {
  if [ -z "$2" ]; then printf '%s\n' "$1"; return 0; fi
  if [ -z "$4" ]; then hold_dispatch "$1" "$2"; return 0; fi
  printf '%s\n' "$1" | awk -v r="$2" -v run="$3" -v prop="$4" '
    function share(a, b,   x, y, i, j, nx, ny) {
      nx = split(a, x, ","); ny = split(b, y, ",")
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] != "" && x[i] == y[j]) return 1
      return 0
    }
    BEGIN {
      n = split(run, a, "\n")
      for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); if (a[i] == "") continue; split(a[i], f, "\t"); nr++; ri[nr] = f[1]; ra[nr] = f[2]; k = split(f[1], t, ","); for (j = 1; j <= k; j++) on[t[j]] = 1 }
      n = split(prop, a, "\n")
      for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); if (a[i] == "") continue; split(a[i], f, "\t"); k = split(f[1], t, ","); for (j = 1; j <= k; j++) pa[t[j]] = f[2] }
    }
    /^dispatch / {
      if (index($0, "	First: ")) { print; next }
      split(substr($0, 10), w, /[ \t]+/); first = w[1]; ok = (first in pa) && pa[first] != ""
      for (j = 1; ok && w[j] ~ /^[0-9]+$/; j++) if (w[j] in on) ok = 0
      for (q = 1; ok && q <= nr; q++) if (ra[q] == "" || share(pa[first], ra[q])) ok = 0
      if (ok) print; else held++
      next
    }
    NF > 0 { print }
    END { if (held) { gsub(/ /, ", #", r); print "held: " held " dispatch goal(s) wait for the running round (#" r ") to land" } }'
}
