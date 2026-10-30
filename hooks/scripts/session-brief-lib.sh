#!/bin/sh
# Pure helpers for the session brief. Nothing here runs git or gh; every
# function takes text and prints text, so tests/run.sh covers each with a
# fixture. The hook (session-brief.sh) gathers the raw lines and calls these.

# json_number JSON KEY
# Print the numeric value of the first "KEY" in JSON, or nothing.
json_number() {
  printf '%s' "$1" | awk -v key="\"$2\"" '
    BEGIN { RS = "\001" }
    {
      i = index($0, key)
      if (i == 0) exit
      s = substr($0, i + length(key))
      if (!sub(/^[ \t\r\n]*:[ \t\r\n]*/, "", s)) exit
      if (match(s, /^-?[0-9]+(\.[0-9]+)?/)) print substr(s, RSTART, RLENGTH)
    }'
}

# pr_line TSV
# TSV is one pull request as "number<TAB>title<TAB>mergeable<TAB>passed
# <TAB>failed<TAB>pending", the shape gh's own jq emits for the hook. Print
# one plain line: "#12 Title (mergeable, CI 3 passed, 1 failed)".
pr_line() {
  printf '%s\n' "$1" | awk -F'\t' '
    {
      number = $1; title = $2; mergeable = tolower($3)
      passed = $4 + 0; failed = $5 + 0; pending = $6 + 0
      if (mergeable == "mergeable") m = "mergeable"
      else if (mergeable == "conflicting") m = "has conflicts"
      else m = "mergeability unknown"
      if (passed + failed + pending == 0) ci = "no CI yet"
      else if (failed > 0) ci = "CI " failed " failed"
      else if (pending > 0) ci = "CI " pending " pending"
      else ci = "CI green"
      printf "#%s %s (%s, %s)\n", number, title, m, ci
    }'
}

# pr_brief_lines FACTS LIMIT
# FACTS is the output of board-now.sh. Print one line per open pull
# request, at most LIMIT, then how many more there are:
# "#12 Title (mergeable, CI green)".
pr_brief_lines() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v limit="${2:-10}" '
    $1 == "pr" {
      total++
      if (total > limit) next
      m = tolower($5)
      if (m == "mergeable") m = "mergeable"; else if (m == "conflicting") m = "has conflicts"; else m = "mergeability unknown"
      r = $4
      if (r == "SUCCESS") ci = "CI green"
      else if (r == "FAILURE" || r == "ERROR") ci = "CI red"
      else if (r == "PENDING" || r == "EXPECTED") ci = "CI running"
      else ci = "no CI yet"
      printf "#%s %s (%s, %s)\n", $2, $3, m, ci
    }
    END { if (total > limit) printf "(and %d more)\n", total - limit }'
}

# state_of_labels LABELS
# LABELS is a comma separated list. Print the state it names as a short
# key: ready, in-progress, waiting-on-owner and so on, accepting both
# "state:in-progress" and "state: in progress". Print "none" when there is
# no state label.
state_of_labels() {
  printf '%s\n' "$1" | tr ',' '\n' | awk '
    { l = tolower($0); gsub(/^[ \t]+|[ \t]+$/, "", l) }
    l ~ /^state:/ { sub(/^state:[ \t]*/, "", l); gsub(/[ \t]+/, "-", l); print l; found = 1; exit }
    END { if (!found) print "none" }'
}

# issues_summary FACTS
# FACTS is the output of board-now.sh. Print the open issues grouped by
# state: one line of counts, then the issues in progress (at most ten),
# those waiting on the owner (at most five) and the first five that are
# ready. Long lists are counted, not printed.
issues_summary() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    function state_of(labels,   n, i, parts, l) {
      n = split(labels, parts, ",")
      for (i = 1; i <= n; i++) {
        l = tolower(parts[i]); gsub(/^[ \t]+|[ \t]+$/, "", l)
        if (l ~ /^state:/) { sub(/^state:[ \t]*/, "", l); gsub(/[ \t]+/, "-", l); return l }
      }
      return "none"
    }
    $1 == "total" { total = $2 }
    $1 == "issue" {
      s = state_of($4); count[s]++; seen++
      item = "#" $2 " " $3
      if (s == "in-progress" && ++ip <= 10) inprog[ip] = item
      if (s == "waiting-on-owner" && ++wo <= 5) owner[wo] = item
      if (s == "ready" && ++rd <= 5) ready[rd] = item
    }
    END {
      if (seen == 0) exit
      if (total == "") total = seen
      order = "ready in-progress waiting-on-owner waiting-on-service blocked parked dated after-launch none"
      n = split(order, keys, " ")
      line = "Issues: " total " open."
      sep = " "
      for (i = 1; i <= n; i++) if (count[keys[i]] > 0) {
        name = keys[i]; gsub(/-/, " ", name); if (name == "none") name = "no state"
        line = line sep count[keys[i]] " " name; sep = ", "
      }
      if (total > seen) line = line " (first " seen " read)"
      print line
      if (ip > 0) { print "In progress:"; for (i = 1; i <= ip && i <= 10; i++) print inprog[i]; if (ip > 10) printf "(and %d more)\n", ip - 10 }
      if (wo > 0) { print "Owner actions waiting:"; for (i = 1; i <= wo && i <= 5; i++) print owner[i]; if (wo > 5) printf "(and %d more)\n", wo - 5 }
      if (rd > 0) { print "Ready:"; for (i = 1; i <= rd && i <= 5; i++) print ready[i]; if (rd > 5) printf "(and %d more)\n", rd - 5 }
    }'
}

# leftover_summary LINES LIMIT
# LINES is one local branch per line as "branch<TAB>ahead behind", from one
# git for-each-ref call. Print how many branches hold commits that are not
# on main, and name at most LIMIT of them with their counts. Prints nothing
# when no branch is ahead.
leftover_summary() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v limit="${2:-5}" '
    NF >= 2 {
      split($2, ab, " ")
      total++
      if (ab[1] + 0 > 0) { ahead++; if (ahead <= limit) names[ahead] = $1 " (" ab[1] + 0 ")" }
    }
    END {
      if (ahead == 0) exit
      printf "Leftover work: %d of %d local branches have commits not on main.\n", ahead, total
      for (i = 1; i <= ahead && i <= limit; i++) print names[i]
      if (ahead > limit) printf "(and %d more)\n", ahead - limit
    }'
}

# worktree_summary PORCELAIN
# PORCELAIN is the output of git worktree list --porcelain. Print one line
# saying how many worktrees there are besides the main checkout and in how
# many folders they sit. Prints nothing when there are none.
worktree_summary() {
  printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | awk '
    /^worktree / {
      n++
      if (n == 1) next
      p = substr($0, 10); sub(/\/[^\/]*$/, "", p)
      # Claude Code puts the worktrees of agents dispatched with
      # isolation: worktree in .claude/worktrees inside the main checkout.
      # That is a known place, not a stray folder.
      if (p ~ /\/\.claude\/worktrees$/) { agent++; next }
      if (!(p in places)) { places[p] = 1; np++ }
    }
    END {
      extra = n - 1
      if (extra <= 0) exit
      printf "Worktrees: %d besides the main checkout, in %d %s", extra - agent, np, (np == 1 ? "folder" : "folders")
      if (agent > 0) printf ", and %d made by Claude Code for dispatched agents in .claude/worktrees", agent
      printf "."
      if (np > 1 || extra > 20) printf " Tidy with: sh scripts/worktrees.sh prune"
      printf "\n"
    }'
}

# log_is_recent MTIME NOW [WINDOW]
# MTIME and NOW are epoch seconds; WINDOW defaults to two hours. Print
# "yes" when the log was written inside the window, "no" otherwise.
log_is_recent() {
  lr_window=${3:-7200}
  case "$1" in ''|*[!0-9]*) echo no; return 0 ;; esac
  case "$2" in ''|*[!0-9]*) echo no; return 0 ;; esac
  if [ $(( $2 - $1 )) -le "$lr_window" ] && [ "$1" -le "$2" ]; then echo yes; else echo no; fi
}

# rate_line RATE NOW [FLOOR]
# RATE is "remaining<TAB>limit<TAB>reset_epoch" from gh api rate_limit.
# Print one line when the budget is low, under FLOOR (default 1000) calls,
# so the queue and the drive know not to poll; print nothing when it is fine
# or unknown. The rate_limit endpoint itself is free, so the brief may read it.
rate_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v floor="${3:-1000}" '
    NR == 1 && NF >= 3 && $1 != "" {
      rem = $1 + 0; lim = $2 + 0; reset = $3 + 0
      if (rem >= floor) exit
      mins = int((reset - now + 59) / 60); if (mins < 0) mins = 0
      if (rem == 0) printf "GitHub API budget: none left of %d; resets in %d minute(s). Do not poll; run the queue with --drain after that.\n", lim, mins
      else printf "GitHub API budget: %d of %d left; resets in %d minute(s). Poll slowly (30s or more) and run one queue at a time.\n", rem, lim, mins
    }'
}

# today_line DATE_TEXT [ZONE]
# The brief's date line: "Today: Friday 2026-10-09, 22:00 PDT. Dates in
# this repository are America/Los_Angeles days; gh and runner timestamps
# are UTC." ZONE is the configured IANA name; when it is empty or the
# TIMEZONE placeholder, the line says the dates are the owner's local day.
today_line() {
  case "$2" in
    ''|TIMEZONE) printf 'Today: %s. Dates in this repository are the owner'\''s local day; gh and runner timestamps are UTC, convert before writing one.\n' "$1" ;;
    *) printf 'Today: %s. Dates in this repository are %s days; gh and runner timestamps are UTC, convert before writing one.\n' "$1" "$2" ;;
  esac
}

# project_slug PATH
# The folder name Claude Code gives a project under ~/.claude/projects:
# every character that is not a letter or a digit becomes "-", so
# C:\Users\me\repo is C--Users-me-repo and /Users/me/repo is -Users-me-repo.
project_slug() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

# newest_handoff LIST
# LIST is one file per line as "mtime<TAB>path". Print the path of the
# newest file whose name starts with "handoff-", or nothing.
newest_handoff() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 2 {
      name = $2; sub(/.*[\/\\]/, "", name)
      if (name !~ /^handoff-/) next
      if ($1 + 0 >= best) { best = $1 + 0; path = $2 }
    }
    END { if (path != "") print path }'
}

# handoff_head TEXT [N]
# Print the first N (default two) lines of the body of a note: front matter
# between --- lines and blank lines are skipped.
handoff_head() {
  hh_n=${2:-2}
  printf '%s\n' "$1" | tr -d '\r' | awk -v n="$hh_n" '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm { next }
    /^[ \t]*$/ { next }
    { print; if (++c >= n) exit }'
}

# trim_section TEXT LIMIT
# Print at most LIMIT lines of TEXT; when more were cut, add one line
# saying how many.
trim_section() {
  printf '%s\n' "$1" | awk -v limit="$2" '
    NF == 0 && NR == 1 { next }
    { lines[NR] = $0; total = NR }
    END {
      shown = (total < limit) ? total : limit
      for (i = 1; i <= shown; i++) print lines[i]
      if (total > limit) printf "(and %d more)\n", total - limit
    }'
}

# brief_sections SOURCE
# Which sections to print for how the session started. A clear prints the
# short form: what is on main and what is in progress. Everything else
# prints the full brief.
brief_sections() {
  case "$1" in
    clear) echo "main inprogress" ;;
    *) echo "main prs queue inprogress leftover screens handoff owner proposal" ;;
  esac
}

# permissions_line SETTINGS_FILE: one line for the owner when the project
# has no .claude/settings.json, so the agent is not first refused at a
# deploy. The agent may not write it; the person runs the wizard.
permissions_line() {
  [ -f "$1" ] && return 0
  printf '%s\n' "Waits on the owner: the agent is not allowed to grant itself permissions, so .claude/settings.json is yours to add. Run node console/cli.js permissions in a terminal."
}

# waits_line ROWS NOW
# ROWS is the queue's waits log (epoch, time, job, busy, total, minutes).
# One sentence on the last seven days' waits for a runner; nothing when
# there were none.
waits_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v since=$(( $2 - 7 * 86400 )) '
    NF >= 6 && $1 + 0 >= since {
      n++; m = $6 + 0; if (m > max) max = m
      if ($5 + 0 > tot) tot = $5 + 0
      if ($4 + 0 > busy) busy = $4 + 0
      if ($4 + 0 < $5 + 0) some = 1
    }
    END {
      if (n == 0) exit
      times = (n == 1) ? "once" : n " times"
      mins = (max == 1) ? "1 minute" : max " minutes"
      if (tot == 0) how = ""
      else if (!some) how = (tot == 1) ? ", when the one runner was busy" : ", when all " tot " were busy"
      else how = ", with up to " busy " of " tot " busy"
      printf "Jobs waited for a runner %s this week, %s at most%s.\n", times, mins, how
    }'
}

# machine_brief_line ROW
# ROW is the runner watch's machine file: epoch, cores, runners here, busy,
# the machine line. Print the line only when the runners exceed one per
# two cores.
machine_brief_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' 'NF >= 5 && $2 + 0 > 0 && $3 + 0 > int($2 / 2) { print $5; exit }'
}

# brief_runner_line RUNNERS CORES
# RUNNERS is the repository's registered self-hosted runners, one per line,
# "name<TAB>status<TAB>busy", from one REST call the brief makes per run.
# Nothing when every registered runner is online, at least two are, and
# they sit within one per two cores; otherwise one plain line.
brief_runner_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v cores="${2:-0}" '
    NF >= 2 { total++; if ($2 == "online") on++; else off = off (off == "" ? "" : ", ") $1 " " $2 }
    END {
      if (total == 0) exit
      allow = int(cores / 2); over = (cores + 0 > 0 && total > allow)
      if (on == 0) { printf "none of the %d self-hosted runners is online, so CI and the merge queue will wait. Start one (scripts/ci/RUNNERS.md).\n", total; exit }
      if (on == total && on >= 2 && !over) exit
      printf "%d of %d online", on, total
      if (off != "") printf "; %s", off
      if (on < 2) printf "; one runner makes every job wait for the last"
      if (over) printf "; %d cores allow %d (one per two cores)", cores, allow
      printf ".\n"
    }'
}

# brief_runner_key_line RUNNERS_JSON
# One line when .claude/runners.json still holds the old "runners" count,
# which nothing reads any more; nothing otherwise.
brief_runner_key_line() {
  printf '%s\n' "$1" | tr -d '\r' | grep -q '"runners"[[:space:]]*:' &&
    echo 'the "runners" key in .claude/runners.json is no longer read; the registered runners and the cores are. Remove it when you next sync.'
  return 0
}
