#!/bin/sh
# The drive's own reader for a partly landed issue (#2047). An issue a merged
# pull request worked on but did not close has no `Left:` line yet: the plan
# proposes one `read-left N` goal for it, once, and the reader leaves the line
# (or closes the issue, or writes the ask when what is left is the owner's).
# `left-read.sh N read|unclear` records the read in .scratch/drive/left-read.tsv
# ("N<TAB>WORD<TAB>EPOCH"), so an issue is read once, never every round.
# Pure; sourced by plan.sh and the plugin's tests.

# left_read_state NUM FILE
# "unread" when no read is recorded, else the recorded word (read or unclear).
left_read_state() {
  [ -f "$2" ] || { echo unread; return 0; }
  tr -d '\r' < "$2" | awk -F'\t' -v n="$1" '$1 == n { w = $2 } END { print (w == "" ? "unread" : w) }'
}

# left_read_hold_why STATE
# The card's words for a partly landed issue. It never says a reader will
# come unless the drive has one at work this round.
left_read_hold_why() {
  case "$1" in
    unread) echo "Part of it landed; the drive has a reader working out what is left of it this round" ;;
    unclear) echo "Part of it landed, and the drive could not tell what is left; it needs your word on what to do with it" ;;
    *) echo "Part of it landed; what is left of it is being written down before it takes an agent" ;;
  esac
}

# left_reader_goals LINES
# LINES are "NUM<TAB>TITLE<TAB>STATE" for the partly landed issues; one
# "read-left NUM<TAB>TITLE" goal for each still unread.
left_reader_goals() {
  printf '%s\n' "$1" | awk -F'\t' '$1 != "" && $3 == "unread" { printf "read-left %s\t%s\n", $1, $2 }'
}

# add_left_readers ROUND LINES
# ROUND with a read-left goal for each unread partly landed issue in LINES,
# before its defer and stop lines (add_goal, drive-lib.sh). A read-left goal
# runs without approval, like ask-owner.
add_left_readers() {
  al_round=$1
  al_goals=$(left_reader_goals "$2")
  [ -n "$al_goals" ] || { printf '%s\n' "$al_round"; return 0; }
  while IFS= read -r al_g; do al_round=$(add_goal "$al_round" "$al_g"); done <<EOF_AL
$al_goals
EOF_AL
  printf '%s\n' "$al_round"
}
