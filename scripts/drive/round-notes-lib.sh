# The drive plan's closing notes: the once-a-day summary, the health note and
# the wake time for a pending pull request, with the two pure readers the
# first two use. Functions only; sourced by plan.sh after round-lib.sh, and
# they read the plan's own variables (settings, auto, snapshot, runs).

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


# The once-a-day summary, when summaryAt is set: due at that local time
# until a comment "Summary for <today>" is on the drive issue (one REST
# call, for the last day's comments only).
summary_note() {
  summary_at=$(setting "$settings" summaryAt)
  drive_issue=${auto#* }
  if [ -n "$summary_at" ] && [ "$auto" != none ] && [ "$(summary_due "$(date +%H:%M)" "$summary_at" no)" = yes ]; then
    today=$(date +%Y-%m-%d)
    since_e=$(( $(date +%s) - 86400 ))
    since=$(date -u -d "@$since_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$since_e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    written=no
    # REST lists oldest first and a busy day holds over a hundred comments: every page is read, never only the first.
    gh api --paginate "repos/{owner}/{repo}/issues/$drive_issue/comments?since=$since&per_page=100" --jq '.[].body' 2>/dev/null | grep -q "^Summary for $today" && written=yes
    [ "$(summary_due "$(date +%H:%M)" "$summary_at" "$written")" = yes ] && echo "summary: due; post today's summary on issue $drive_issue, starting \"Summary for $today\""
  fi
}

# The health note, when healthNote is set: a recommendation, never a pause.
health_note() {
  health_cmd=$(setting "$settings" healthCommand)
  if [ -n "$health_cmd" ]; then
    if command -v timeout >/dev/null 2>&1; then hv=$(timeout 30 sh -c "$health_cmd" 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d ' ')
    else hv=$(sh -c "$health_cmd" 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d ' '); fi
    health_line "$(setting "$settings" healthName)" "$hv" "$(setting "$settings" healthAbove)"
  fi
}

# A pending pull request: say when to look again. One REST call for recent runs.
wake_note() {
  pend_pr=$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "pr" && $4 == "pending" { print $2; exit }')
  if [ -n "$pend_pr" ]; then
    [ -n "$runs" ] || runs=$(gh api "repos/{owner}/{repo}/actions/runs?per_page=50" --jq '.workflow_runs[] | [.status, (.run_started_at // .created_at | fromdateiso8601), (.updated_at | fromdateiso8601), .path, .event, .head_branch] | @tsv' 2>/dev/null | tr -d '\r')
    branch=$(gh api "repos/{owner}/{repo}/pulls/$pend_pr" --jq .head.ref 2>/dev/null | tr -d '\r')
    # The pending run is the one for that pull request's branch, else the first not completed.
    pending=$(printf '%s\n' "$runs" | awk -F'\t' -v b="$branch" '$1 != "completed" && $1 != "" && b != "" && $6 == b { print; exit }')
    [ -n "$pending" ] || pending=$(printf '%s\n' "$runs" | awk -F'\t' '$1 != "completed" && $1 != "" { print; exit }')
    started=$(printf '%s\n' "$pending" | awk -F'\t' '{ print $2 }')
    durations=$(run_durations "$runs" "$(printf '%s\n' "$pending" | awk -F'\t' '{ print $4 }')" "$(printf '%s\n' "$pending" | awk -F'\t' '{ print $5 }')")
    secs=$(wake_after "$durations" "$started" "$(date +%s)")
    [ -n "$secs" ] && echo "wake: $secs seconds, PR $pend_pr"
  fi
}
