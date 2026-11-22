#!/bin/sh
# required_parts_say: split out of gate-lib.sh (which was over its line
# limit) so each file stays small. Needs lib.sh's class_parts, already
# sourced by every caller of this file. Functions only.

# required_parts_say CLASSES RULES CHECKS
# For a pull request whose own run must prove its test parts (own_run_decide
# or full_run_decide said "yes"), the parts CLASSES calls for (the "!parts"
# lines of RULES, as class_parts reads them) that did not pass on this
# commit: one plain line each, naming the part and the classes whose
# "!parts" line called for it, so a refusal names the rule that decided it
# was needed (#2318, "says which rule decided a part was not needed").
# CHECKS is "name<TAB>outcome" per check run on the commit (queue/state.sh's
# check_lines): a matrix part's own check is named "tests (NAME)" by GitHub,
# whatever the job's own name. Nothing when every part called for passed;
# "green" from the one summary check is not enough when one of these is
# skipped or still red, since a later run of the same commit (after the pull
# request's title, body or labels changed) can report success having asked
# for fewer parts than the files still call for.
required_parts_say() {
  rp_rules=$2
  printf '%s\n' "$(class_parts "$1" "$rp_rules")" | while IFS="$(printf '\t')" read -r rp_name rp_cmd; do
    [ -n "$rp_name" ] || continue
    rp_why=$(printf '%s\n' "$rp_rules" | tr -d '\r' | awk -v n="$rp_name" '
      { sub(/#.*/, "") } $1 != "!parts" { next }
      { rest = $0; sub(/^[ \t]*!parts[ \t]+[^ \t]+[ \t]*/, "", rest); m = split(rest, ps, ";")
        for (i = 1; i <= m; i++) { p = ps[i]; gsub(/^[ \t]+/, "", p); if (index(p, n "=") == 1) { c = $2; gsub(/,/, ", ", c); print c; exit } } }')
    rp_state=$(printf '%s\n' "$3" | tr -d '\r' | awk -F'\t' -v n="tests ($rp_name)" '$1 == n { print tolower($2); f = 1 } END { if (!f) print "missing" }')
    case "$rp_state" in
      success) ;;
      missing) echo "$rp_name: its class ($rp_why) calls for this test part, on its \"!parts\" line of classes.txt, but \"tests ($rp_name)\" has not run on this commit" ;;
      *) echo "$rp_name: its class ($rp_why) calls for this test part, on its \"!parts\" line of classes.txt, but \"tests ($rp_name)\" is $rp_state on this commit, not passed" ;;
    esac
  done
}
