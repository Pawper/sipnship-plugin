#!/bin/sh
# Pure helpers for the drive's rounds (specs/010-work): the project's round
# choices, what REST says of each open pull request, landing through the
# queue, the daily summary, the health note, and the one-round-at-a-time
# rule. Nothing here runs git or gh; every function takes text and prints
# text, and tests/run.sh covers each. drive_settings needs json_field
# (hooks/scripts/lib.sh) and json_number (hooks/scripts/session-brief-lib.sh).

# drive_settings JSON
# The round's choices from .claude/project-drive.json, each with its
# default, one "KEY<TAB>VALUE" line each, in this order:
#   unitsPerRound      the most units one round holds (default 2)
#   dispatchModel      the model each unit's agent runs on (default empty:
#                      the model the agent-model hook allows for its tier)
#   setAsideAfterReds  a pull request red this many times is set aside
#                      (default 2; 0 never)
#   summaryAt          local HH:MM for the once-a-day summary (default
#                      empty: no summary)
#   healthCommand      healthNote.command, which prints one number
#                      (default empty: no health note)
#   healthName         healthNote.name: what the number is, in plain words
#   healthAbove        healthNote.above: over this, a restart is recommended
drive_settings() {
  ds_n=$(json_number "$1" unitsPerRound); [ -n "$ds_n" ] || ds_n=2
  ds_r=$(json_number "$1" setAsideAfterReds); [ -n "$ds_r" ] || ds_r=2
  ds_h=$(printf '%s' "$1" | awk 'BEGIN { RS = "\001" } { i = index($0, "\"healthNote\""); if (!i) exit; s = substr($0, i); j = index(s, "{"); k = index(s, "}"); if (!j || !k || k < j) exit; print substr(s, j, k - j + 1) }')
  printf 'unitsPerRound\t%s\n' "$ds_n"
  printf 'dispatchModel\t%s\n' "$(json_field "$1" dispatchModel)"
  printf 'setAsideAfterReds\t%s\n' "$ds_r"
  printf 'summaryAt\t%s\n' "$(json_field "$1" summaryAt)"
  ds_cmd=""; ds_name=""; ds_above=""
  if [ -n "$ds_h" ]; then
    ds_cmd=$(json_field "$ds_h" command)
    ds_name=$(json_field "$ds_h" name); [ -n "$ds_name" ] || ds_name="the machine's health figure"
    ds_above=$(json_number "$ds_h" above)
  fi
  printf 'healthCommand\t%s\nhealthName\t%s\nhealthAbove\t%s\n' "$ds_cmd" "$ds_name" "$ds_above"
}

# setting SETTINGS KEY
# One value from drive_settings' output.
setting() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'
}

# overlay_rest SNAPSHOT LINES
# LINES are what REST says of each open pull request, one per line:
# "NUMBER<TAB>MERGEABLE_STATE<TAB>REDS<TAB>HELD(yes|no)". mergeable_state
# "dirty" (it conflicts with main) makes it conflicting; "unknown" or
# nothing leaves what the board said; anything else is mergeable. REDS and
# HELD become the pull request's seventh and eighth fields. Every other
# line passes through.
overlay_rest() {
  { printf '%s\n' "$2" | sed 's/^/R	/'; printf '%s\n' "$1" | sed 's/^/S	/'; } | tr -d '\r' | awk -F'\t' -v OFS='\t' '
    $1 == "R" && $2 != "" { st[$2] = $3; reds[$2] = $4; held[$2] = $5; next }
    $1 == "S" && $2 == "pr" && ($3 in st) {
      m = $6
      if (st[$3] == "dirty") m = "conflicting"
      else if (st[$3] != "" && st[$3] != "unknown") m = "mergeable"
      print $2, $3, $4, $5, m, $7, (reds[$3] == "" ? 0 : reds[$3] + 0), (held[$3] == "yes" ? "yes" : "no")
      next
    }
    $1 == "S" && NF > 1 { sub(/^S\t/, ""); print }'
}

# red_count SHAS
# One failed check run per line, its head commit first. How many times the
# pull request was red: the different commits that failed, so re-running
# one commit counts once.
red_count() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 != "" && !($1 in s) { s[$1] = 1; n++ } END { print n + 0 }'
}

# held_by LABELS BODY
# "yes" when the queue holds the pull request: a queue:hold or hold label
# (LABELS comma separated) or a "Queue: hold" line in its body; else "no".
held_by() {
  if printf '%s\n' "$1" | tr ',' '\n' | tr -d '\r' | grep -qixE 'queue:hold|hold'; then echo yes; return 0; fi
  if printf '%s\n' "$2" | tr -d '\r' | grep -qiE '^Queue: hold'; then echo yes; return 0; fi
  echo no
}

# green_minutes RUNS BRANCH NOW
# RUNS as run_durations reads them (status, start, end, path, event,
# branch). The whole minutes since the newest completed run on BRANCH
# ended: how long its pull request has sat green. Nothing when none ran.
green_minutes() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v b="$2" -v now="$3" '
    $1 == "completed" && $6 == b && $3 + 0 > last { last = $3 + 0 }
    END { if (last > 0) print int((now - last) / 60) }'
}

# landing_goals ROUND AGES [AFTER]
# For a project whose queue lands green work by itself. AGES is
# "NUMBER<TAB>MINUTES" per green pull request. The merge and merge-batch
# goals become one "drain N N" goal (one drain, in the background) when
# any has sat green AFTER minutes (default 15), and otherwise one
# unnumbered "landing" line saying the queue lands them. A round left with
# no goal says work is in flight.
landing_goals() {
  printf '%s\n' "$1" | awk -v ages="$2" -v after="${3:-15}" '
    BEGIN {
      n = split(ages, al, "\n")
      for (i = 1; i <= n; i++) { split(al[i], f, "\t"); if (f[1] != "" && f[2] + 0 > oldest) oldest = f[2] + 0 }
    }
    function land() {
      if (prs == "") return
      if (oldest >= after) { print "drain " prs "\t(green for " oldest " minutes; one drain lands them)"; goals++ }
      else print "landing " prs ": green; the queue lands them, and a drain is proposed if they sit " after " minutes"
      prs = ""
    }
    /^merge(-batch)? / { for (i = 2; i <= NF; i++) prs = prs (prs == "" ? "" : " ") $i; next }
    { land() }
    /^stop:/ {
      if (goals == 0 && $0 ~ /proposal ready/) { print "stop: work is in flight; nothing to propose until it lands"; next }
      print; next
    }
    !/^(defer |hold |landing )/ && NF > 0 { goals++ }
    { print }'
}

# summary_due NOW AT WRITTEN
# NOW and AT are local "HH:MM"; WRITTEN is yes when today's summary is on
# the drive issue already. "yes" when AT is set, NOW is at or past it and
# nothing is written yet; "no" otherwise.
summary_due() {
  if [ -z "$2" ] || [ "$3" = yes ]; then echo no; return 0; fi
  sd_now=$(printf '%s' "$1" | awk -F: '{ print $1 * 60 + $2 }')
  sd_at=$(printf '%s' "$2" | awk -F: '{ print $1 * 60 + $2 }')
  if [ "$sd_now" -ge "$sd_at" ]; then echo yes; else echo no; fi
}

# health_line NAME VALUE ABOVE
# The health note: a recommendation, never a pause. Over ABOVE it
# recommends a restart; at or under it, it says the figure is fine; with no
# figure, it says so. Work goes on in every case.
health_line() {
  case "$2" in
    ''|*[!0-9.]*) printf 'health: %s could not be read; work goes on\n' "$1"; return 0 ;;
  esac
  if [ -n "$3" ] && awk -v v="$2" -v a="$3" 'BEGIN { exit !(v + 0 > a + 0) }'; then
    printf 'health: %s is %s, over %s; a restart is recommended, and work goes on\n' "$1" "$2" "$3"
  else
    printf 'health: %s is %s, fine\n' "$1" "$2"
  fi
}

# comment_pages COUNT
# The pages of 100 that hold an issue's newest comments: the last two, or
# 1 when there are 100 or fewer. GitHub lists comments oldest first.
comment_pages() {
  case "$1" in ''|*[!0-9]*) echo 1; return 0 ;; esac
  cp_last=$(( ($1 + 99) / 100 )); [ "$cp_last" -ge 1 ] || cp_last=1
  if [ "$cp_last" -gt 1 ]; then echo "$(( cp_last - 1 )) $cp_last"; else echo 1; fi
}

# running_round COMMENTS IN_PROGRESS
# COMMENTS are the drive issue's comments, one per line. IN_PROGRESS is the
# open issues labeled In progress, one number per line. Prints the issues
# of the latest started round (its units, not its held work) that are still
# in progress, space separated: while any is, that round is running and no
# other starts. Nothing when no round runs.
running_round() {
  rr_units=$(printf '%s\n' "$1" | tr -d '\r' | grep -F 'sipnship-proposal {"status":"started"' | tail -n 1 \
    | sed 's/.*sipnship-proposal {"status":"started",//; s/"held":.*//' | grep -oE '"issues":\[[0-9, ]*\]' | grep -oE '[0-9]+')
  [ -n "$rr_units" ] || return 0
  printf '%s\n' "$2" | tr -d '\r' | awk -v u="$(printf '%s ' $rr_units)" '
    BEGIN { n = split(u, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    ($1 in want) && !($1 in seen) { seen[$1] = 1; out = out (out == "" ? "" : " ") $1 }
    END { if (out != "") print out }'
}

# start_request LINE
# The login in a "Start this round" request, "Queue request: start-round by
# LOGIN" ("#0" after start-round allowed); nothing for any other line.
start_request() {
  printf '%s\n' "$1" | tr -d '\r' | sed -nE 's/^Queue request: start-round( #0)? by ([A-Za-z0-9][A-Za-z0-9-]{0,38})(: .*)?$/\2/p' | head -n 1
}

# hold_dispatch GOALS RUNNING
# While a round runs (RUNNING names its issues), approved dispatch goals
# wait for it to land; every other goal goes ahead. Prints the goals left,
# then one "held:" line when any dispatch waited.
hold_dispatch() {
  if [ -z "$2" ]; then printf '%s\n' "$1"; return 0; fi
  printf '%s\n' "$1" | awk -v r="$2" '
    /^dispatch / { held++; next }
    NF > 0 { print }
    END { if (held) { gsub(/ /, ", #", r); print "held: " held " dispatch goal(s) wait for the running round (#" r ") to land" } }'
}
