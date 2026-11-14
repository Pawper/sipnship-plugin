#!/bin/sh
# What the plan ranks first: the ready issues that fix a failure on main.
# Pure: every function takes text and prints text; tests/run.sh covers each.

# fixes_main TEXT
# "yes" when an issue's title and the start of its body say it puts right a
# failure on main: the word main, a failing word (fail, red, broken) and a
# test, check or build, with the product's own screens called "main" (the
# Main card, the main tab) set aside first. Such an issue is ranked ahead of
# feature work and bundles, as an issue labeled ci-red is.
fixes_main() {
  printf '%s\n' "$1" | tr 'A-Z' 'a-z' | tr -d '\r' | sed -E 's/(^|[^a-z])main (card|tab|band|screen|page|view|row|rows|heading)([^a-z]|$)/ /g' | awk '
    /(^|[^a-z])main([^a-z]|$)/ && /(fail|red|broken|broke)/ && /(test|check|build)/ { hit = 1 }
    END { print (hit ? "yes" : "no") }'
}

# mainfix_numbers FACTS
# FACTS are board-now.sh's lines. The numbers, space separated, of the ready
# issues that fix a failure on main (fixes_main on the title and body start).
mainfix_numbers() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 == "issue" && ("," $4 ",") ~ /,(state: ?)?ready,/ { print $2 "\t" $3 " " $6 }' | while IFS='	' read -r mn_n mn_t; do
    if [ "$(fixes_main "$mn_t")" = yes ]; then printf '%s ' "$mn_n"; fi
  done | sed 's/ $//'
}

# lead_main_fixes ROUND
# The goals a fix for a failure on main puts first (apply_units marks them
# "First: A fix for a failure on main") move to the top of the round, so the
# proposal opens with them and the approval never holds them behind the round
# their failure blocks. Every other line keeps its order.
lead_main_fixes() {
  printf '%s\n' "$1" | awk '
    index($0, "First: A fix for a failure on main") { lead[++l] = $0; next }
    { rest[++r] = $0 }
    END { for (i = 1; i <= l; i++) print lead[i]; for (i = 1; i <= r; i++) print rest[i] }'
}

# hold_drain_for_main ROUND MAINFIX
# While a ready issue fixes a failure on main (MAINFIX, space separated), a
# drain would batch pull requests against the same failure and close on it:
# each "drain N N" goal becomes an unnumbered "landing" line saying the round
# waits on the fix. With no such issue the round passes unchanged.
hold_drain_for_main() {
  [ -n "$2" ] || { printf '%s\n' "$1"; return 0; }
  printf '%s\n' "$1" | awk -v fix="$2" '
    /^drain / {
      prs = $0; sub(/\t.*/, "", prs); sub(/^drain /, "", prs); f = fix; gsub(/ /, " #", f)
      print "landing " prs ": green, but main fails the same test; the round waits on the fix for main (#" f ") before they are batched"
      next
    }
    { print }'
}
