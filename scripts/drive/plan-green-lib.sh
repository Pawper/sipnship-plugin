#!/bin/sh
# How long each green pull request has sat green, read from the pull request's
# own head commit (its check runs), never from a window of the repository's
# latest workflow runs: in a project whose housekeeping workflows run on every
# issue event, that window is used up in hours and a green pull request's age
# read as nothing. Sourced by plan.sh after round-lib.sh.

# head_green_minutes LINES NOW
# LINES are a head commit's check runs, "STATUS<TAB>COMPLETED_EPOCH" each. The
# whole minutes since the newest one finished; nothing when none finished or
# the lines are empty (the age is then unknown, never 0).
head_green_minutes() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" '
    $1 == "completed" && $2 + 0 > last { last = $2 + 0 }
    END { if (last > 0) print int((now - last) / 60) }'
}

# green_ages GREEN_PRS SHAS NOW
# GREEN_PRS are pull request numbers, space separated; SHAS are
# "NUMBER<TAB>HEAD_SHA" lines. Prints "NUMBER<TAB>MINUTES" for each, with "?" as
# the minutes when the head commit's check runs cannot be read (one REST call each).
green_ages() {
  for ga_p in $1; do
    ga_sha=$(printf '%s\n' "$2" | awk -F'\t' -v n="$ga_p" '$1 == n { print $2; exit }')
    ga_m=""
    if [ -n "$ga_sha" ]; then
      ga_m=$(head_green_minutes "$(gh api "repos/{owner}/{repo}/commits/$ga_sha/check-runs?per_page=100" --jq '.check_runs[] | [.status, ((.completed_at // "") | if . == "" then "" else fromdateiso8601 | tostring end)] | @tsv' 2>/dev/null)" "$3")
    fi
    printf '%s\t%s\n' "$ga_p" "${ga_m:-?}"
  done
}

# settled_red LINES
# LINES are a head commit's check runs, "STATUS<TAB>CONCLUSION". "yes" when every
# one has finished and any failed, was cancelled or timed out: the board's rollup
# can still read pending then, and the pull request is red, not running.
settled_red() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    $1 == "" { next }
    $1 != "completed" { open = 1 }
    $2 == "failure" || $2 == "cancelled" || $2 == "timed_out" { bad = 1 }
    END { print ((bad && !open) ? "yes" : "no") }'
}

# head_settled_red SHA: settled_red for a head commit (one REST call).
head_settled_red() {
  settled_red "$(gh api "repos/{owner}/{repo}/commits/$1/check-runs?per_page=100" --jq '.check_runs[] | [.status, (.conclusion // "")] | @tsv' 2>/dev/null)"
}

# say_every_pr ROUND SNAPSHOT
# Every open pull request gets a line in the proposal, whatever its checks say.
# One no line of ROUND names (a held one, one whose checks are still running or
# whose merge state is unknown) gets an unnumbered one before the stop line: a
# "hold" for a held one, a "busy" for the rest. Other lines pass through.
say_every_pr() {
  { printf '%s\n' "$1" | sed 's/^/R	/'; printf '%s\n' "$2" | sed 's/^/S	/'; } | tr -d '\r' | awk -F'\t' '
    $1 == "R" { line[++n] = $2; for (i = 3; i <= NF; i++) line[n] = line[n] "\t" $i; head = $2; if (head ~ /^(merge|merge-batch|fix-pr|set-aside|merge-main|busy|landing|drain|hold) /) { sub(/[:\t].*/, "", head); k = split(head, w, / +/); for (j = 2; j <= k; j++) said[w[j]] = 1 } next }
    $1 == "S" && $2 == "pr" && !($3 in said) {
      if ($9 == "yes") extra = extra "hold " $3 "\t" $4 "\tIts pull request is held for your read; nothing is sent to it\n"
      else extra = extra "busy " $3 "\t" $4 "\t" (($5 == "pending") ? "its checks are still running" : "GitHub has not said yet whether it can merge") "\n"
    }
    END {
      for (i = 1; i <= n; i++) { if (line[i] ~ /^stop:/ && !done) { printf "%s", extra; done = 1 } print line[i] }
      if (!done) printf "%s", extra
    }'
}
