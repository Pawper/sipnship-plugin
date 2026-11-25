#!/bin/sh
# Lines of a proposal that contradict a hold already on it. Sourced by plan.sh. Pure.

# drop_asks_for_after_holds ROUND
# An issue that names what it comes after, where that still waits, is a "hold N ... (after: M)"
# line and is never also an "ask-owner N": its words that look like a decision belong to the issue
# it follows, and a question put to the builder about it would carry no decision (#1875).
drop_asks_for_after_holds() {
  printf '%s\n' "$1" | awk -F'\t' '
    { line[++n] = $0 }
    /^hold [0-9]+/ && /\(after: [0-9]+\)/ { h = $1; sub(/^hold /, "", h); sub(/ .*/, "", h); held[h] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        if (line[i] ~ /^ask-owner [0-9]+/) { a = line[i]; sub(/^ask-owner /, "", a); sub(/[ \t].*/, "", a); if (a in held) continue }
        print line[i]
      }
    }'
}

# hold_for_publish_view AREAS UNITS COMMENTS SNAPSHOT RUN_UNITS TITLES
# The plan frees a running unit that evidence says nobody is on (RUN_UNITS leaves it out), but
# publish-round.sh reads "running" from the round's comments and the In progress labels alone, and
# refuses a unit in the area of any unit it counts. So that the round still publishes, a unit publish
# counts and the plan did not is read once more as running, and a ready unit in its area becomes a
# hold behind it rather than a proposal publish refuses (#2710). SNAPSHOT is the plan's snapshot
# lines; every issue it shows In progress counts, as the label does for publish.
hold_for_publish_view() {
  hp_inprog=$(printf '%s\n' "$4" | awk -F'\t' '$1 == "issue" && $4 == "in-progress" { print $2 }')
  hp_extra=$(printf '%s\n' "$(running_units "$3" "$hp_inprog")" | awk -v have="$(printf '%s\n' "$5" | tr '\n' '~')" '
    BEGIN { n = split(have, a, "~"); for (i = 1; i <= n; i++) if (a[i] != "") seen[a[i]] = 1 }
    NF && !($0 in seen)')
  if [ -z "$hp_extra" ]; then printf '%s\n' "$2"; else area_units "$1" "$2" "$hp_extra" "$6"; fi
}
