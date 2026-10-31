# Pure parts of gate.sh: main's full gate, after a quiet hour. Main gets no
# run per landing; each landing's own green pull-request run is its record.
# Once an hour a scheduled run asks gate_decide whether to run every test
# part of every class. No network here.

# gate_decide HEAD LAST_GATED PUSHED_EPOCH NOW_EPOCH QUIET_MINUTES [EVENT]
# "run" or "skip: <why>". It runs when main's head is not the last head a
# gate ran on and main has been quiet (no landing) for QUIET_MINUTES. A
# workflow_dispatch run always runs.
gate_decide() {
  [ "${6:-}" = workflow_dispatch ] && { echo run; return; }
  if [ -n "$2" ] && [ "$1" = "$2" ]; then echo "skip: main has not moved since the last gate"; return; fi
  [ -n "$3" ] || { echo "skip: main's last landing time is not known"; return; }
  gd_ago=$(( ($4 - $3) / 60 ))
  if [ "$gd_ago" -lt "$5" ]; then echo "skip: main moved $gd_ago minutes ago; the gate waits for $5 quiet minutes"; return; fi
  echo run
}

# last_gated RUNS: the newest gate that ran its tests, from lines of
#   head-sha  conclusion  created-epoch  tests-ran(yes|no)
# newest first; prints "head-sha<TAB>conclusion<TAB>created-epoch", or
# nothing. A run whose gate skipped is not a gate.
last_gated() {
  printf '%s\n' "$1" | awk -F '\t' '$4 == "yes" && ($2 == "success" || $2 == "failure") { print $1 "\t" $2 "\t" $3; exit }'
}

# gate_holds_deploy GATED LANDED_EPOCH: the reason a deploy is held, or
# nothing. GATED is last_gated's line. Only a red gate newer than the
# head's landing holds; a head that landed after it carries its own green
# landing run and goes.
gate_holds_deploy() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | awk -F '\t' -v landed="$2" '$2 == "failure" && (landed == "" || $3 + 0 >= landed + 0) { print "main'\''s full gate is red on " substr($1, 1, 7) " and nothing landed since" }'
}

# gate_main_state GATED: main's state as the last gate saw it: "green" or
# "red", or "unknown" when no gate has run its tests yet. GATED is
# last_gated's line. Main gets no run per landing, so this is the one place
# its state is read; the newest push run of CI is not a record of main.
gate_main_state() {
  printf '%s\n' "$1" | awk -F '\t' 'NF >= 3 && $2 == "success" { print "green"; f = 1; exit } NF >= 3 && $2 == "failure" { print "red"; f = 1; exit } END { if (!f) print "unknown" }'
}

# gate_checked_at GATED: the time main was last fully checked, as an ISO
# UTC time, or nothing when no gate has run.
gate_checked_at() {
  gc_e=$(printf '%s\n' "$1" | awk -F '\t' 'NF >= 3 && $3 + 0 > 0 { print $3; exit }')
  [ -n "$gc_e" ] || return 0
  date -u -d "@$gc_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$gc_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# main_unassigned RUNS NOW IDLE
# RUNS is main_in_flight's lines with the created epoch as a fifth field.
# Print "id<TAB>minutes" for each push run on main that has sat queued
# over ten minutes while the runners were idle (IDLE "yes"): GitHub has not
# handed it to a machine, so the wait is GitHub's, not a runner's.
main_unassigned() {
  [ "${3:-}" = yes ] || return 0
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" '
    NF >= 5 && $2 == "main" && $4 == "push" && ($3 == "queued" || $3 == "waiting" || $3 == "requested") && $5 + 0 > 0 && now - $5 > 600 { printf "%s\t%d\n", $1, int((now - $5) / 60) }'
}

# main_waiting_said UNASSIGNED: the dashboard's plain line for
# main_unassigned's output ("id<TAB>minutes"), or nothing.
main_waiting_said() {
  mw=$(printf '%s\n' "$1" | awk -F '\t' 'NF >= 2 { print $2; exit }')
  [ -n "$mw" ] || return 0
  echo "A run on main has waited $mw minutes with every runner idle: waiting on GitHub, not on a machine."
}
