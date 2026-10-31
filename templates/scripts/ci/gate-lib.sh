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
