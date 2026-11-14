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
