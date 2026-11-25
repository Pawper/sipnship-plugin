#!/bin/sh
# For the nightly audit (#2607): the hours in the last day when the REST budget reached zero, and in the hour before
# each one how much was spent and how much of it this machine's agents made. The guard keeps a history file of
# readings ("R", when, left, limit, reset) and agent calls ("C", when): SIPNSHIP_BUDGET_LOG, else
# ~/.sipnship/gh-budget-history.txt. GitHub does not say which caller made a request, so what the agents' own calls do
# not explain is the app, the drive's scripts, check polling and the coordinator's looks together. Prints one line per
# hour, and nothing when the budget never reached zero, or there is no history. NOW (epoch seconds) is for tests.
log=${SIPNSHIP_BUDGET_LOG:-${HOME:-.}/.sipnship/gh-budget-history.txt}
[ -f "$log" ] || exit 0
now=${NOW:-$(date -u +%s)}
hours=${SINCE_HOURS:-24}
awk -F'\t' -v now="$now" -v from="$((now - hours * 3600))" '
  function commas(n,  s) { s = sprintf("%d", n); while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]$|[0-9][0-9][0-9],/, ",&", s); return s }
  $1 == "R" && NF >= 5 && $2 + 0 >= from { r++; rt[r] = $2 + 0; rl[r] = $3 + 0; rim[r] = $4 + 0; rs[r] = $5 + 0 }
  $1 == "C" && NF >= 2 && $2 + 0 >= from - 3600 { c++; ct[c] = $2 + 0; ck[c] = ($3 == "" ? "agent" : $3) }
  END {
    for (i = 1; i <= r; i++) {
      if (rl[i] != 0 || rs[i] in done) continue
      done[rs[i]] = 1
      start = rs[i] - 3600; hi = 0; seen = 0
      for (j = 1; j <= r; j++) if (rs[j] == rs[i]) { if (!seen || rl[j] > hi) hi = rl[j]; seen = 1 }
      calls = 0; delete kinds; for (k = 1; k <= c; k++) if (ct[k] >= start && ct[k] < rs[i]) { calls++; kinds[ck[k]]++ }
      split("agent checks queue drive coordinator", order, " "); by = ""
      for (o = 1; o <= 5; o++) if (kinds[order[o]] > 0) by = by (by == "" ? "" : ", ") order[o] " " kinds[order[o]]
      printf "The REST budget reached zero in the hour ending %s UTC: about %s of %s spent, %d of them reads made by this machine'"'"'s agents%s; the rest is the app'"'"'s own reads, which the service counts by tab on Cost.\n", \
        strftime("%Y-%m-%d %H:%MZ", rs[i], 1), commas(rim[i] - 0), commas(rim[i]), calls, (by == "" ? "" : " (" by ")")
    }
  }' "$log"
