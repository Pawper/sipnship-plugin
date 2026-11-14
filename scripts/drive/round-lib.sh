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
# "NUMBER<TAB>MERGEABLE_STATE<TAB>REDS<TAB>HELD(yes|no)[<TAB>BUSY(yes|no)[<TAB>PENDING(yes|no)[<TAB>MAINRED]]]".
# mergeable_state "dirty" (it conflicts with main) makes it conflicting;
# "unknown" or nothing leaves what the board said; anything else is
# mergeable. REDS, HELD, BUSY and PENDING (its head commit's checks are
# still running) and MAINRED (none, fixed or waiting: its reds came from a test broken on main, and main is
# right again, or not yet) become the pull request's seventh to eleventh fields. Every
# other line passes through.
overlay_rest() {
  { printf '%s\n' "$2" | sed 's/^/R	/'; printf '%s\n' "$1" | sed 's/^/S	/'; } | tr -d '\r' | awk -F'\t' -v OFS='\t' '
    $1 == "R" && $2 != "" { st[$2] = $3; reds[$2] = $4; held[$2] = $5; busy[$2] = $6; pend[$2] = $7; mred[$2] = $8; next }
    $1 == "S" && $2 == "pr" && ($3 in st) {
      m = $6
      if (st[$3] == "dirty") m = "conflicting"
      else if (st[$3] != "" && st[$3] != "unknown") m = "mergeable"
      print $2, $3, $4, $5, m, $7, (reds[$3] == "" ? 0 : reds[$3] + 0), (held[$3] == "yes" ? "yes" : "no"), (busy[$3] == "yes" ? "yes" : "no"), (pend[$3] == "yes" ? "yes" : "no"), (mred[$3] == "" ? "none" : mred[$3])
      next
    }
    $1 == "S" && NF > 1 { sub(/^S\t/, ""); print }'
}

# recently_touched HEAD_EPOCH COMMENT_EPOCH NOW [MINUTES]
# "yes" when the pull request's head commit (or a time given second) is under
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

# main_reds PR_FAILS MAIN_CHECKS
# Which of a pull request's red commits main itself caused. PR_FAILS are the
# failing checks of its red commits, "SHA<TAB>EPOCH<TAB>CHECK" a line (EPOCH is
# when that run began); MAIN_CHECKS are main's finished checks,
# "EPOCH<TAB>CHECK<TAB>CONCLUSION" a line. A red commit is main's when every
# check it failed was also failing on main at the time: main's newest result
# for that check at or before the pull request's run is a failure. Prints those
# commits, one per line; a commit with no named failing check is never main's.
main_reds() {
  { printf '%s\n' "$2" | sed 's/^/M	/'; printf '%s\n' "$1" | sed 's/^/P	/'; } | tr -d '\r' | awk -F'\t' '
    $1 == "M" && $2 != "" { m++; me[m] = $2 + 0; mc[m] = $3; mr[m] = $4; next }
    $1 == "P" && $2 != "" {
      sha = $2; if (!(sha in seen)) { seen[sha] = 1; order[++n] = sha }
      best = -1; r = ""
      for (i = 1; i <= m; i++) if (mc[i] == $4 && me[i] <= $3 + 0 && me[i] > best) { best = me[i]; r = mr[i] }
      if (r != "failure") own[sha] = 1
    }
    END { for (i = 1; i <= n; i++) if (!(order[i] in own)) print order[i] }'
}

# main_now_green PR_FAILS MAIN_CHECKS
# "yes" when main's newest result for every check the pull request failed is
# not a failure: main has been put right since. Both as main_reds reads them.
# "no" when any is still failing or unknown, and when there are no failures.
main_now_green() {
  { printf '%s\n' "$2" | sed 's/^/M	/'; printf '%s\n' "$1" | sed 's/^/P	/'; } | tr -d '\r' | awk -F'\t' '
    $1 == "M" && $2 != "" && $2 + 0 >= (($3 in at) ? at[$3] : -1) { at[$3] = $2 + 0; res[$3] = $4; next }
    $1 == "P" && $2 != "" { n++; if (!($4 in res) || res[$4] == "failure") bad = 1 }
    END { print ((n > 0 && !bad) ? "yes" : "no") }'
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

# landing_goals ROUND AGES [AFTER [BATCH [MEMBERS [HELD [IDLE]]]]]
# For a project whose queue lands green work by itself. AGES is
# "NUMBER<TAB>MINUTES" per green pull request. The merge and merge-batch
# goals become one "drain N N" goal (one drain, in the background) when
# any has sat green AFTER minutes (default 15), and otherwise one
# unnumbered "landing" line saying the queue lands them. A round left with
# no goal says work is in flight.
#
# BATCH is the number of an open pull request that carries the queue's batch
# marker: its members are already landing, so no drain is proposed (a second
# queue process would break the one-queue rule) and the line names the batch.
# MEMBERS (space separated) are the pull requests that batch carries: each is
# "landing", never part of a drain, whatever its age. HELD (space separated)
# are pull requests held for the builder to read: never counted toward a
# drain, never named as landing. IDLE is the whole minutes since the queue
# last had nothing in flight (queue_idle_minutes); a green pull request is
# counted green only from then, so a queue that has just finished is not
# beaten to the next landing. An age of "?" (its head commit's checks could
# not be read) is never 0: it counts as old enough, and the line says so.
landing_goals() {
  printf '%s\n' "$1" | awk -v ages="$2" -v after="${3:-15}" -v batch="${4:-}" -v members=" ${5:-} " -v held=" ${6:-} " -v idle="${7:-}" '
    BEGIN {
      n = split(ages, al, "\n")
      for (i = 1; i <= n; i++) { split(al[i], f, "\t"); if (f[1] != "") { if (f[2] == "?") { unk[f[1]] = 1; age[f[1]] = after + 0 } else age[f[1]] = f[2] + 0 } }
    }
    function land(   w, k, m, mem, rest, oldest, a) {
      if (prs == "") return
      m = split(prs, w, " "); mem = ""; rest = ""; oldest = 0; anyunk = 0
      for (k = 1; k <= m; k++) {
        if (index(held, " " w[k] " ")) continue
        if (index(members, " " w[k] " ")) { mem = mem (mem == "" ? "" : " ") w[k]; continue }
        rest = rest (rest == "" ? "" : " ") w[k]
        a = age[w[k]] + 0; if (a > oldest) { oldest = a; anyunk = (w[k] in unk) }
      }
      if (idle != "" && idle + 0 < oldest) { oldest = idle + 0; anyunk = 0 }
      if (mem != "") print "landing " mem ": members of the queue batch" (batch != "" ? " (pull request " batch ")" : "") " already landing; no drain is proposed"
      prs = ""
      if (rest == "") return
      if (batch != "") print "landing " rest ": a queue batch (pull request " batch ") is already landing them; no drain is proposed"
      else if (oldest >= after) { print "drain " rest "\t(green" (anyunk ? ", for how long is not known" : " for " oldest " minutes") "; one drain lands them)"; goals++ }
      else print "landing " rest ": green; the queue lands them, and a drain is proposed if they sit " after " minutes"
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

# batch_members BODY
# The pull request numbers an open batch pull request's body names, once each,
# space separated.
batch_members() {
  printf '%s\n' "$1" | tr -d '\r' | grep -o '#[0-9][0-9]*' | tr -d '#' | sort -un | tr '\n' ' ' | sed 's/ $//'
}

# queue_idle_minutes RUNS NOW
# RUNS as green_minutes reads them. Nothing when the queue has not run; 0 while
# a Queue drain run is in progress or queued (something is in flight); else the
# whole minutes since the newest one ended.
queue_idle_minutes() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" '
    $4 ~ /queue-drain\.yml$/ {
      if ($1 != "completed") { busy = 1; next }
      if ($3 + 0 > last) last = $3 + 0
    }
    END { if (busy) print 0; else if (last > 0) print int((now - last) / 60) }'
}

# plan_landing ROUND AGES BATCH_PR SNAPSHOT RUNS
# landing_goals with what plan.sh knows: the open batch's members (one REST
# read of its body), the held pull requests of SNAPSHOT, and the queue's idle
# minutes from RUNS.
plan_landing() {
  pl_members=""
  [ -z "$3" ] || pl_members=$(batch_members "$(gh api "repos/{owner}/{repo}/pulls/$3" --jq '.body // ""' 2>/dev/null)")
  pl_held=$(printf '%s\n' "$4" | awk -F'\t' '$1 == "pr" && $8 == "yes" { printf "%s ", $2 }')
  landing_goals "$1" "$2" 15 "$3" "$pl_members" "$pl_held" "$(queue_idle_minutes "$5" "$(date +%s)")"
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
        delete owed[a[1] " " a[2]]; delete line[a[1] " " a[2]]
        if (a[1] == "start-now" && a[2] == "0") for (k in owed) if (index(k, "start-now ? ") == 1) { delete owed[k]; delete line[k] }
        next
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
      key = kind " " n; text = kind (n == "" ? "" : " " n) " by " who
      # A round-wide Start now with words (the builder own, after the form) is printed with them, one line each, so the drive reads what was asked: no issue number is "?".
      if (kind == "start-now" && n == "0" && match($3, /by [A-Za-z0-9-]+: ./)) { key = "start-now ? " $1; text = "start-now ? by " who ": " substr($3, RSTART + 5 + length(who)) }
      if (!(key in owed)) order[++c] = key
      owed[key] = who; line[key] = text
    }
    END { for (i = 1; i <= c; i++) if (order[i] in owed) { print line[order[i]]; delete owed[order[i]] } }'
}

# hold_dispatch GOALS RUNNING
# While a round runs (RUNNING names its issues), approved dispatch goals
# wait for it to land, except a unit that went First (a project priority, with its own area: apply_units); every other goal goes ahead. Prints the goals left,
# then one "held:" line when any dispatch waited.
hold_dispatch() {
  if [ -z "$2" ]; then printf '%s\n' "$1"; return 0; fi
  printf '%s\n' "$1" | awk -v r="$2" '
    /^dispatch / { if (index($0, "	First: ")) { print; next } held++; next }
    NF > 0 { print }
    END { if (held) { gsub(/ /, ", #", r); print "held: " held " dispatch goal(s) wait for the running round (#" r ") to land" } }'
}

# mark_waiting_ok VERDICT
# VERDICT is ask_verdict's word for the issue's latest ask (scripts/ci/ask-lib.sh, the one reader).
# "yes" only for an ask in the shape (choices, exactly one recommended): the
# plan's mark-waiting then runs without approval, like ask-owner.
mark_waiting_ok() { if [ "$1" = one ] || [ "$1" = instructions ]; then echo yes; else echo no; fi; }
