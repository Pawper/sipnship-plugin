#!/bin/sh
# A round is over when every issue it took is settled (specs/023-drive-on-work, #2128). Settled is: closed, or handed
# on in a way that needs nothing more from this round (what is left filed as its own issue and the original closed,
# waiting on the owner with its question, or blocked with what it waits on named). An issue of a landed unit that is
# still open in Ready with no word of how it was handed on is unsettled, and the round is not over while one is.
# Pure helpers, text in and text out; settle-round.sh does the gh work and the tests cover each. Sourced by
# approval.sh and plan.sh after round-state-lib.sh.

# settle_candidates COMMENTS ALL_OPEN FACTS
# COMMENTS are the drive issue's comments (started_units' shape), ALL_OPEN every open pull request's number, one a
# line, FACTS "NUMBER<TAB>STATE<TAB>NOTED" a line for each open issue (STATE is its State label's word, NOTED "yes"
# when a "Settled:" note was written on it since the round started). Prints, one a line, the issues of the latest
# started round whose unit's pull request is no longer open (it landed or closed) and that are still open in Ready
# with no such note: the issues that round has not settled.
settle_candidates() {
  started_units "$1" | awk -F'\t' -v open="$2" -v facts="$3" '
    BEGIN {
      n = split(open, a, "\n"); for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); if (a[i] != "") op[a[i]] = 1 }
      n = split(facts, a, "\n")
      for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); split(a[i], f, "\t"); if (f[1] != "") { st[f[1]] = f[2]; nt[f[1]] = f[3] } }
    }
    $1 != "" && !($1 in op) {
      m = split($2, is, " ")
      for (i = 1; i <= m; i++) if ((is[i] in st) && st[is[i]] == "ready" && nt[is[i]] != "yes" && !(is[i] in seen)) { seen[is[i]] = 1; print is[i] }
    }'
}

# settling_say NUMBERS
# The Work tab's line for the round's last step: "settling 2 issues"; nothing when none is left.
settling_say() {
  ss_n=$(printf '%s\n' "$1" | tr -d '\r' | awk 'NF { c++ } END { print c + 0 }')
  case "$ss_n" in 0) return 0 ;; 1) echo "settling 1 issue" ;; *) echo "settling $ss_n issues" ;; esac
}
