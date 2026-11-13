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
# "NUMBER<TAB>MERGEABLE_STATE<TAB>REDS<TAB>HELD(yes|no)[<TAB>BUSY(yes|no)[<TAB>PENDING(yes|no)]]".
# mergeable_state "dirty" (it conflicts with main) makes it conflicting;
# "unknown" or nothing leaves what the board said; anything else is
# mergeable. REDS, HELD, BUSY and PENDING (its head commit's checks are
# still running) become the pull request's seventh to tenth fields. Every
# other line passes through.
overlay_rest() {
  { printf '%s\n' "$2" | sed 's/^/R	/'; printf '%s\n' "$1" | sed 's/^/S	/'; } | tr -d '\r' | awk -F'\t' -v OFS='\t' '
    $1 == "R" && $2 != "" { st[$2] = $3; reds[$2] = $4; held[$2] = $5; busy[$2] = $6; pend[$2] = $7; next }
    $1 == "S" && $2 == "pr" && ($3 in st) {
      m = $6
      if (st[$3] == "dirty") m = "conflicting"
      else if (st[$3] != "" && st[$3] != "unknown") m = "mergeable"
      print $2, $3, $4, $5, m, $7, (reds[$3] == "" ? 0 : reds[$3] + 0), (held[$3] == "yes" ? "yes" : "no"), (busy[$3] == "yes" ? "yes" : "no"), (pend[$3] == "yes" ? "yes" : "no")
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
#
# A fourth argument, BATCH, is the number of an open pull request that
# carries the queue's batch marker: its members are already landing, so no
# drain is proposed (a second queue process would break the one-queue rule)
# and the line names the batch.
landing_goals() {
  printf '%s\n' "$1" | awk -v ages="$2" -v after="${3:-15}" -v batch="${4:-}" '
    BEGIN {
      n = split(ages, al, "\n")
      for (i = 1; i <= n; i++) { split(al[i], f, "\t"); if (f[1] != "" && f[2] + 0 > oldest) oldest = f[2] + 0 }
    }
    function land() {
      if (prs == "") return
      if (batch != "") print "landing " prs ": a queue batch (pull request " batch ") is already landing them; no drain is proposed"
      else if (oldest >= after) { print "drain " prs "\t(green for " oldest " minutes; one drain lands them)"; goals++ }
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

# comment_pages COUNT
# The pages of 100 that hold an issue's newest comments: the last two, or
# 1 when there are 100 or fewer. GitHub lists comments oldest first.
comment_pages() {
  case "$1" in ''|*[!0-9]*) echo 1; return 0 ;; esac
  cp_last=$(( ($1 + 99) / 100 )); [ "$cp_last" -ge 1 ] || cp_last=1
  if [ "$cp_last" -gt 1 ]; then echo "$(( cp_last - 1 )) $cp_last"; else echo 1; fi
}

# start_request LINE
# The login in a "Start this round" request, "Queue request: start-round by
# LOGIN" ("#0" after start-round allowed); nothing for any other line.
start_request() {
  printf '%s\n' "$1" | tr -d '\r' | sed -nE 's/^Queue request: start-round( #0)? by ([A-Za-z0-9][A-Za-z0-9-]{0,38})(: .*)?$/\2/p' | head -n 1
}

# work_requests COMMENTS START_SINCE HOLD_SINCE
# COMMENTS are the drive issue's comments, one "at<TAB>login<TAB>body" a line,
# oldest first. Prints the requests the drive still owes an answer, one
# "start-next N by LOGIN", "start-now N by LOGIN", "hold-agent N by LOGIN" or
# "start-round by LOGIN" a line (a start-now with no issue reads as "start-now 0 by LOGIN"). A request is the exact form, left by the App
# or by the person it names; an answer in the form `Queue answer: KIND #N:
# outcome` (start-round's N is 0) spends it; one older than its SINCE (a UTC
# time, compared as text) has already been told it did not happen. A request
# nobody answered stays owed on every later read, so the drive reports it.
work_requests() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v s="$2" -v h="$3" '
    {
      if (match($3, /^Queue answer: (start-next|start-now|hold-agent|start-round) #[0-9]+: /)) {
        split(substr($3, 15), a, /[ #:]+/)
        if (a[1] == "start-round") a[2] = ""
        delete owed[a[1] " " a[2]]; next
      }
      if ($3 !~ /^Queue request: ((start-next|start-now|hold-agent) #[0-9]+|start-now|start-round( #0)?) by [A-Za-z0-9][A-Za-z0-9-]*(: .*)?$/) next
      split($3, w, " ")
      kind = w[3]; n = w[4]; who = w[6]
      if (kind == "start-round") { n = ""; who = (w[4] == "by") ? w[5] : w[6] }
      # The round-wide Start now names no issue: N is 0, as start-round answers.
      if (kind == "start-now" && w[4] == "by") { n = "0"; who = w[5] }
      sub(/^#/, "", n); sub(/:$/, "", who)
      if ($2 != who && $2 !~ /\[bot\]$/) next
      if ($1 < (kind == "hold-agent" ? h : s)) next
      key = kind " " n
      if (!(key in owed)) order[++c] = key
      owed[key] = who
    }
    END { for (i = 1; i <= c; i++) if (order[i] in owed) { split(order[i], k, " "); print (k[2] == "" ? k[1] : k[1] " " k[2]), "by", owed[order[i]]; delete owed[order[i]] } }'
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
#
# deferred_holds ROUND RUNNING ISSUE_AREAS: RUNNING (running_units' lines,
# "ISSUES<TAB>AREAS", commas) and ISSUE_AREAS ("NUMBER<TAB>AREAS" lines) let a
# deferred unit in an area a running unit owns wait on that unit instead:
# "hold: 5 | after: 12 14 | why: ...", since publish-round.sh refuses it as a
# unit in the running unit's area. Both are optional.
deferred_holds() {
  printf '%s\n' "$1" | awk -v running="${2:-}" -v ia="${3:-}" '
    BEGIN {
      n = split(running, rl, "\n"); for (i = 1; i <= n; i++) if (rl[i] != "") { split(rl[i], f, "\t"); nr++; rs[nr] = f[1]; ra[nr] = f[2] }
      n = split(ia, il, "\n"); for (i = 1; i <= n; i++) if (il[i] != "") { split(il[i], f, "\t"); iarea[f[1]] = f[2] }
    }
    /^defer [0-9]+ unit\(s\):/ {
      s = $0; i = match(s, /\(#[^)]*\)$/); if (!i) next
      s = substr(s, RSTART + 1, RLENGTH - 2)
      n = split(s, pieces, /, /)
      for (k = 1; k <= n; k++) {
        p = pieces[k]; gsub(/#/, "", p)
        split(p, first, " "); hit = ""; who = ""; mine = iarea[first[1]]
        if (mine != "") for (q = 1; q <= nr && hit == ""; q++) {
          na = split(mine, ma, ","); nb = split(ra[q], mb, ",")
          for (x = 1; x <= na && hit == ""; x++) for (y = 1; y <= nb; y++) if (ma[x] != "" && ma[x] == mb[y]) { hit = ma[x]; who = rs[q] }
        }
        if (hit != "") { gsub(/,/, " ", who); print "hold: " p " | after: " who " | why: Its area, " hit ", is owned by the running unit" }
        else print "hold: " p " | why: No free runner this round"
      }
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
