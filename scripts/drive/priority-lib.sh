#!/bin/sh
# A project's priorities (the drive's Config, "priorities"): an ordered list of
# areas (names from the project's areas file) or labels whose ready work goes
# first, right after fixes for a failure on main. Each entry is one string,
# "NAME: why", for example "review: it unblocks your reviews"; the words after
# the colon are what a unit that went first says in its line ("First: ...").
# Pure: every function takes text and prints text; tests/run.sh covers each.
# Needs areas-lib.sh (round_areas) and area-plan-lib.sh (unit_areas).

# drive_priorities CONFIG
# The entries of the config's "priorities" array, one "NAME<TAB>WHY" a line in
# the order written. Nothing when the key is absent.
drive_priorities() {
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" } { i = index($0, "\"priorities\""); if (!i) exit; s = substr($0, i); j = index(s, "["); k = index(s, "]"); if (!j || !k) exit; print substr(s, j + 1, k - j - 1) }' \
    | grep -o '"[^"]*"' | sed 's/^"//;s/"$//' | while IFS= read -r dp_e; do
      dp_n=${dp_e%%:*}; dp_n=$(printf '%s' "$dp_n" | sed 's/^ *//;s/ *$//')
      dp_w=""; case "$dp_e" in *:*) dp_w=${dp_e#*:}; dp_w=$(printf '%s' "$dp_w" | sed 's/^ *//;s/ *$//') ;; esac
      if [ -n "$dp_n" ]; then printf '%s\t%s\n' "$dp_n" "$dp_w"; fi
    done
}

# priority_issues PRIORITIES GUESSES FACTS AREAS
# GUESSES are the plan's "NUMBER<TAB>TITLE<TAB>FILES" lines for the ready
# issues, FACTS board-now's lines (the labels), AREAS the areas file's text.
# For each ready issue in a priority area or carrying a priority label, one
# "NUMBER<TAB>RANK<TAB>WHY" line, RANK its entry's place in the list (1 is
# first); the earliest entry it matches wins. Nothing with no priorities.
priority_issues() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$2" | while IFS="	" read -r pi_n pi_t pi_f; do
    [ -n "$pi_n" ] || continue
    pi_labels=$(printf '%s\n' "$3" | awk -F'\t' -v n="$pi_n" '$1 == "issue" && $2 == n { print tolower($4); exit }')
    pi_areas=$(unit_areas "$4" "$pi_f")
    printf '%s\n' "$1" | awk -F'\t' -v a=",$pi_areas," -v l=",$pi_labels," '
      { name = tolower($1); r++ }
      index(a, "," name ",") || index(l, "," name ",") { print r "\t" $2; exit }' | while IFS="	" read -r pi_r pi_w; do
        printf '%s\t%s\t%s\n' "$pi_n" "$pi_r" "$pi_w"
      done
  done
}
