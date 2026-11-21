#!/bin/sh
# A green change is never passed over silently. Sourced by
# scripts/ci/merge-queue.sh and scripts/ci/publish-state.sh; functions only.
#
# One afternoon a release green at 4:46 PM and another change green at 4:58 PM
# were still open at 5:02 PM though two drains had started and ended between:
# the first held the release for a change still in its checks, the second left
# both out because the round the drive had named was still running its own,
# and its last line said "Nothing is green yet". Now every round names each
# green change it leaves, with why, in its log and on the Queue tab, and a
# green change it has no reason to leave is landed with the rest.

# drain_passed_over OPEN BASE PICK TRIED RUSH REDMAIN: the green changes aimed
# at BASE that this round leaves, one "number<TAB>why" a line in number order;
# why is empty when no reason applies, and the drain then lands it. OPEN is
# the round's rows (number, draft, mergeable, rollup, base); PICK what it
# lands; TRIED what this drain already tried; RUSH the rush change landing
# first and REDMAIN the red-main issue whose fix lands first, either empty.
# A draft is not ready, so it is not named.
drain_passed_over() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v pick=" $(printf '%s' "$3" | tr '\n' ' ') " -v tried=" $4 " -v rush="$5" -v red="$6" '
    NF >= 5 && $5 == base && $2 == "false" && $4 == "green" && index(pick, " " $1 " ") == 0 {
      if (index(tried, " " $1 " ") > 0) why = "this drain already tried it and it could not land (its line above says why); the next drain tries it again"
      else if (toupper($3) == "CONFLICTING") why = "it conflicts with main; its agent merges main in first"
      else if (rush != "") why = "a rush change (#" rush ") lands first, and this one right after"
      else if (red != "") why = "main is red (issue #" red "); the change that fixes it lands first"
      else why = ""
      printf "%s\t%s\n", $1, why
    }' | sort -n
}

# passed_round: the drain's look, once a round and after the pick, at the
# green changes the pick leaves (round, open, base, pick, tried, rush_now and
# rm_issue set by the round). Says each with its reason, keeps them in
# passed.tsv for the Queue tab, adds to the pick any it has no reason to
# leave, and sets passed_n for the round's last line.
passed_round() {
  pr_lines=$(drain_passed_over "$open" "$base" "$pick" "$tried" "$(printf '%s' "${rush_now:-}" | awk '{ print $1 }')" "${rm_issue:-}")
  printf '%s\n' "$pr_lines" | awk -F'\t' '$2 != ""' > "$flaky_dir/passed.tsv" 2>/dev/null || true
  passed_n=$(printf '%s\n' "$pr_lines" | awk -F'\t' '$2 != "" { n++ } END { print n + 0 }')
  printf '%s\n' "$pr_lines" | awk -F'\t' '$2 != ""' | while IFS="$(printf '\t')" read -r pr_n pr_why; do
    say "round $round: #$pr_n is green and does not land in this round: $pr_why."
  done
  pr_add=$(printf '%s\n' "$pr_lines" | awk -F'\t' 'NF >= 1 && $1 != "" && $2 == "" { print $1 }')
  [ -n "$pr_add" ] || return 0
  say "round $round: $(printf '#%s ' $pr_add)green with nothing holding it back, so it lands now with the rest."
  pick=$(printf '%s\n%s\n' "$pick" "$pr_add" | sed '/^$/d' | sort -n -u)
}

# passed_open_say OPEN PASSED: OPEN (number, title, state, say per line) with
# each green change PASSED names (number<TAB>why per line) saying why it is
# not landing; any other row is unchanged.
passed_open_say() {
  { printf '%s\n' "$2" | tr -d '\r' | awk -F'\t' 'NF >= 2 && $2 != "" { printf "P\t%s\t%s\n", $1, $2 }'; printf '%s\n' "$1" | awk '{ print "O\t" $0 }'; } | awk -F'\t' -v OFS='\t' '
    $1 == "P" { why[$2] = $3; next }
    $1 == "O" && NF >= 4 { if ($4 == "green" && ($2 in why)) $5 = "green, and not in this landing: " why[$2]; print $2, $3, $4, $5 }'
}
