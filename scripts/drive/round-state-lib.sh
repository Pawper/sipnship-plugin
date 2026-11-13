#!/bin/sh
# Pure helpers for what the drive's started round is doing (specs/010-work): which
# of its units are running, which issues they hold out of dispatch, and
# whether a pull request's newest commit is still waiting on its checks.
# Nothing here runs git or gh; every function takes text and prints text,
# and tests/run.sh covers each. Sourced by approval.sh and plan.sh.

# running_round COMMENTS IN_PROGRESS
# COMMENTS are the drive issue's comments, one per line. IN_PROGRESS is the
# open issues labeled In progress, one number per line. Prints the issues
# of the latest started round (its units, not its held work) that are still
# in progress, space separated: while any is, that round is running and no
# other starts. Nothing when no round runs.
#
# A unit also counts as running while its pull request is open, whatever
# State its issues show (a change held for the builder's read leaves them
# Ready): OPEN_PRS, a third argument, is the open pull requests' numbers one
# per line, and every issue of a started unit whose "pr" is among them is
# running. It stops when the pull request merges or the unit is set aside.
running_round() {
  rr_units=$(started_units "$1")
  [ -n "$rr_units" ] || return 0
  printf '%s\n' "$rr_units" | awk -F'\t' -v inprog="$2" -v open="${3:-}" '
    BEGIN {
      n = split(inprog, a, "\n"); for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); if (a[i] != "") ip[a[i]] = 1 }
      n = split(open, a, "\n"); for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); if (a[i] != "") op[a[i]] = 1 }
    }
    {
      m = split($2, is, " ")
      for (i = 1; i <= m; i++) if ((is[i] in ip) || ($1 != "" && ($1 in op))) if (!(is[i] in seen)) { seen[is[i]] = 1; out = out (out == "" ? "" : " ") is[i] }
    }
    END { if (out != "") print out }'
}

# started_units COMMENTS
# The units of the latest started round on the drive issue (its sipnship-
# proposal marker, not its held work), one "PR<TAB>ISSUES" line each: PR is
# the unit's open-able pull request number (empty before one is opened),
# ISSUES the unit's issue numbers, space separated.
started_units() {
  printf '%s\n' "$1" | tr -d '\r' | grep -F 'sipnship-proposal {"status":"started"' | tail -n 1 \
    | sed 's/.*sipnship-proposal {"status":"started",//; s/"held":.*//' | awk '
      {
        n = split($0, parts, /\{"issues":/)
        for (i = 2; i <= n; i++) {
          p = parts[i]; iss = p; sub(/\].*/, "", iss); sub(/^\[/, "", iss); gsub(/ /, "", iss); gsub(/,/, " ", iss)
          pr = ""; if (match(p, /"pr":[0-9]+/)) pr = substr(p, RSTART + 5, RLENGTH - 5)
          if (iss != "") print pr "\t" iss
        }
      }'
}

# started_pr_holds COMMENTS OPEN_PRS TITLES
# For plan.sh: every issue of a started unit whose pull request is open is
# never proposed for dispatch. One "hold<TAB>NUMBER<TAB>TITLE<TAB>WHY" line
# per such issue (the shape of bundle-lib's hold_reasons, shown on an
# unnumbered line). TITLES is "NUMBER<TAB>TITLE" lines for the issues it
# knows; one it does not know prints with an empty title.
started_pr_holds() {
  started_units "$1" | awk -F'\t' -v open="$2" -v titles="$3" '
    BEGIN {
      n = split(open, a, "\n"); for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); if (a[i] != "") op[a[i]] = 1 }
      n = split(titles, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, "\t"); if (f[1] != "") tt[f[1]] = f[2] }
    }
    $1 != "" && ($1 in op) {
      m = split($2, is, " ")
      for (i = 1; i <= m; i++) if (!(is[i] in seen)) {
        seen[is[i]] = 1
        printf "hold\t%s\t%s\tIts pull request (#%s) is still open and its unit is running; no agent is started on it\n", is[i], tt[is[i]], $1
      }
    }'
}

# started_ready_holds COMMENTS OPEN_PRS FACTS SNAPSHOT
# started_pr_holds for the plan: only the Ready issues of the snapshot (the
# others are not proposed anyway), titles from the board FACTS, each issue once.
started_ready_holds() {
  started_pr_holds "$1" "$2" "$(printf '%s\n' "$3" | awk -F'\t' '$1 == "issue" { print $2 "\t" $3 }')" \
    | awk -F'\t' -v r="$(printf '%s\n' "$4" | awk -F'\t' '$1 == "issue" && $4 == "ready" { printf "%s ", $2 }')" '
      BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
      ($2 in w) && !seen[$2]++'
}

# checks_pending LINES
# LINES are a head commit's check runs, one "STATUS<TAB>CONCLUSION" each
# (GitHub's words). "yes" when any is not completed yet: the newest commit is
# still waiting on its checks, whatever an older commit did. Else "no".
checks_pending() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 != "" && $1 != "completed" { p = 1 } END { print (p ? "yes" : "no") }'
}
