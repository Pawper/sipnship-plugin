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
# "NUMBER<TAB>MERGEABLE_STATE<TAB>REDS<TAB>HELD(yes|no)[<TAB>BUSY(yes|no)]".
# mergeable_state "dirty" (it conflicts with main) makes it conflicting;
# "unknown" or nothing leaves what the board said; anything else is
# mergeable. REDS, HELD and BUSY become the pull request's seventh, eighth
# and ninth fields. Every other line passes through.
overlay_rest() {
  { printf '%s\n' "$2" | sed 's/^/R	/'; printf '%s\n' "$1" | sed 's/^/S	/'; } | tr -d '\r' | awk -F'\t' -v OFS='\t' '
    $1 == "R" && $2 != "" { st[$2] = $3; reds[$2] = $4; held[$2] = $5; busy[$2] = $6; next }
    $1 == "S" && $2 == "pr" && ($3 in st) {
      m = $6
      if (st[$3] == "dirty") m = "conflicting"
      else if (st[$3] != "" && st[$3] != "unknown") m = "mergeable"
      print $2, $3, $4, $5, m, $7, (reds[$3] == "" ? 0 : reds[$3] + 0), (held[$3] == "yes" ? "yes" : "no"), (busy[$3] == "yes" ? "yes" : "no")
      next
    }
    $1 == "S" && NF > 1 { sub(/^S\t/, ""); print }'
}

# recently_touched HEAD_EPOCH COMMENT_EPOCH NOW [MINUTES]
# "yes" when the pull request's head commit or its newest comment is under
# MINUTES (default 30) old: someone, likely an agent in another session, is
# working on it, so the drive sends no agent of its own. "no" otherwise,
# and for a time it does not have.
recently_touched() {
  rt_m=${4:-30}
  for rt_t in "$1" "$2"; do
    case "$rt_t" in ''|*[!0-9]*) continue ;; esac
    if [ $(( $3 - rt_t )) -lt $(( rt_m * 60 )) ]; then echo yes; return 0; fi
  done
  echo no
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
    !/^(defer |hold |landing |busy )/ && NF > 0 { goals++ }
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

# work_requests COMMENTS START_SINCE HOLD_SINCE
# COMMENTS are the drive issue's comments, one "at<TAB>login<TAB>body" a line,
# oldest first. Prints the Work tab's requests the drive still owes, one
# "start-next N by LOGIN" or "hold-agent N by LOGIN" a line. A request is the
# exact form, left by the App or by the person it names; an answer in the
# form `Queue answer: KIND #N: outcome` spends it; one older than its SINCE
# (a UTC time, compared as text) has already been told it did not happen.
work_requests() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v s="$2" -v h="$3" '
    {
      if (match($3, /^Queue answer: (start-next|hold-agent) #[0-9]+: /)) {
        split(substr($3, 15), a, /[ #:]+/); delete owed[a[1] " " a[2]]; next
      }
      if ($3 !~ /^Queue request: (start-next|hold-agent) #[0-9]+ by [A-Za-z0-9][A-Za-z0-9-]*(: .*)?$/) next
      split($3, w, " ")
      kind = w[3]; n = w[4]; sub(/^#/, "", n); who = w[6]; sub(/:$/, "", who)
      if ($2 != who && $2 !~ /\[bot\]$/) next
      if ($1 < (kind == "start-next" ? s : h)) next
      if (!((kind " " n) in owed)) order[++c] = kind " " n
      owed[kind " " n] = who
    }
    END { for (i = 1; i <= c; i++) if (order[i] in owed) { split(order[i], k, " "); print k[1], k[2], "by", owed[order[i]]; delete owed[order[i]] } }'
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

# agent_runners LISTING [CAP]
# How many agents may work at once, from the machines GitHub lists: LISTING
# is one "STATUS<TAB>BUSY(true|false)" line per registered runner. The count
# is the runners online and not busy, less one kept for the queue and its
# checks (never below one while any is free); CAP, when above 0, is the most
# the project's config allows. Prints "AGENTS<TAB>ONLINE<TAB>FREE", or
# nothing when GitHub listed no runner (the caller falls back to the config).
agent_runners() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v cap="${2:-0}" '
    NF >= 2 { seen++; if ($1 == "online") { online++; if ($2 != "true") free++ } }
    END {
      if (!seen) exit
      a = free - 1; if (free > 0 && a < 1) a = 1; if (a < 0) a = 0
      if (cap + 0 > 0 && a > cap + 0) a = cap + 0
      printf "%d\t%d\t%d\n", a, online + 0, free + 0
    }'
}

# agent_runners_say LINE [CAP]
# LINE is agent_runners' output: the plan's heading words, naming the number
# used and where it came from ("5 runners online, 4 free for agents").
agent_runners_say() {
  printf '%s\n' "$1" | awk -F'\t' -v cap="${2:-0}" '
    NF >= 3 {
      s = $2 " runner" ($2 == 1 ? "" : "s") " online, " $1 " free for agents"
      if (cap + 0 > 0 && $3 - 1 > cap + 0) s = s " (the config caps it at " cap ")"
      print s
    }'
}

# deferred_holds ROUND
# ROUND is the plan's lines. For the plan's "defer N unit(s): ... (#5, #6 #7)"
# line, print the round file's lines for the units it left out, one
# "hold: 5 | why: No free runner this round" each, so the Work tab says
# why a unit is not in the round instead of saying nothing. A unit with
# several issues is one hold line naming all of them.
deferred_holds() {
  printf '%s\n' "$1" | awk '
    /^defer [0-9]+ unit\(s\):/ {
      s = $0; i = match(s, /\(#[^)]*\)$/); if (!i) next
      s = substr(s, RSTART + 1, RLENGTH - 2)
      n = split(s, pieces, /, /)
      for (k = 1; k <= n; k++) { p = pieces[k]; gsub(/#/, "", p); print "hold: " p " | why: No free runner this round" }
    }'
}

# sized_line SAID: the round file's line for how the plan sized the round,
# from the plan's own words ("5 runners online, 4 free for agents"); empty
# when it said nothing. The Work tab's "Why this many" tip reads it.
sized_line() {
  [ -n "$1" ] || return 0
  printf 'sized: %s\n' "$(printf '%s' "$1" | tr -d '\r' | cut -c1-160)"
}

# mark_waiting_ok VERDICT
# VERDICT is ask_verdict's word for the issue's latest ask (scripts/ci/ask-lib.sh, the one reader).
# "yes" only for an ask in the shape (choices, exactly one recommended): the
# plan's mark-waiting then runs without approval, like ask-owner.
mark_waiting_ok() { if [ "$1" = one ]; then echo yes; else echo no; fi; }
