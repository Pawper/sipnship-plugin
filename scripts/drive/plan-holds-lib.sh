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
