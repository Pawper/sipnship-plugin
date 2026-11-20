#!/bin/sh
# A goal a round finds already done (the pull request merged by hand, the
# issue closed, a release already published) is dropped from the approved
# list the first time, with one line saying so; without this it is carried
# from the same static proposal and reply and skipped again on every tick
# after (#2052). goal-done.sh (production) writes the record this reads;
# this file is the pure half, covered by tests/run.sh.

# drop_done_goals GOALS DONE
# GOALS are approval.sh's approved goal lines; DONE the lines already
# recorded as done (goal-done.sh writes .scratch/drive/done.tsv, one exact
# goal line per line). Prints GOALS with every line DONE already names
# removed; passes GOALS through unchanged when DONE is empty.
drop_done_goals() {
  [ -n "$2" ] || { printf '%s\n' "$1"; return 0; }
  printf '%s\n' "$1" | awk -v done="$(printf '%s\n' "$2" | tr -d '\r')" '
    BEGIN { n = split(done, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1 }
    NF && !($0 in skip)'
}
