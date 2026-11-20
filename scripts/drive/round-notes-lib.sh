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


# held_wait_note LINES NOW
# LINES hold one "NUMBER<TAB>SINCE" per pull request the round is held behind (SINCE is the epoch of its
# newest commit, when its red began); NOW is the epoch now. Prints one "waits:" line, in the shape the
# round file reads, naming each held over an hour with how long; nothing when none is. Units in other
# areas start whatever this says; it only makes the wait visible.
held_wait_note() {
  printf '%s\n' "$1" | awk -F'\t' -v now="$2" '
    NF >= 2 && $2 + 0 > 0 && now - $2 > 3600 {
      m = int((now - $2) / 60); d = int(m / 60) " hour" (m >= 120 ? "s " : " ") (m % 60) " minutes"
      say = say (say == "" ? "" : "; ") "pull request " $1 " for " d
    }
    END { if (say != "") print "waits: the round has been held behind " say "; units in other areas start anyway" }'
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
    # A read that failed is "not read", never "not written": a drive that believed "due" would post the summary again (#1788).
    if sn_body=$(gh api --paginate "repos/{owner}/{repo}/issues/$drive_issue/comments?since=$since&per_page=100" --jq '.[].body' 2>/dev/null); then
      printf '%s\n' "$sn_body" | grep -qE "^[ *_#>]*Summary for[^0-9]*$today" && written=yes
      [ "$(summary_due "$(date +%H:%M)" "$summary_at" "$written")" = yes ] && echo "summary: due; post today's summary on issue $drive_issue, starting \"Summary for $today\""
    else
      echo "summary: not read; GitHub could not be reached, so whether today's summary is posted is not known"
    fi
  fi
}

# The health note, when healthNote is set: a recommendation, never a pause.
health_read() {
  [ -z "${health_done:-}" ] || return 0
  health_done=yes; hv=""; health_cmd=$(setting "$settings" healthCommand)
  [ -n "$health_cmd" ] || return 0
  if command -v timeout >/dev/null 2>&1; then hv=$(timeout 30 sh -c "$health_cmd" 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d ' ')
  else hv=$(sh -c "$health_cmd" 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d ' '); fi
}
health_note() {
  health_read
  if [ -n "$health_cmd" ]; then
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

# plugin_behind_note INSTALLED RELEASED
# One line when the plugin copy running the drive is older than the latest
# release, with both versions, how far behind when that is a count of patch
# releases, and how to update; nothing when it is current or either is not
# known. A scheduled tick runs the installed copy, so fixes already released
# come back in the plan until it is updated, and the drive reports the line.
plugin_behind_note() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  [ "$(ver_lt "$1" "$2")" = yes ] || return 0
  pb_n=$(awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); if (x[1] == y[1] && x[2] == y[2]) print y[3] - x[3] }')
  pb_how=""
  if [ "$pb_n" = 1 ]; then pb_how=" (1 release behind)"; elif [ -n "$pb_n" ]; then pb_how=" ($pb_n releases behind)"; fi
  echo "plugin: this drive runs $1, and $2 is released$pb_how. Faults fixed in a release come back in the plan until the installed copy is updated. A scheduled drive updates it itself, first thing (sh plugin/scripts/release/update-installed.sh), and says in its report on the drive issue which release it moved to; the new scripts apply from its next start."
}

# plugin_note: the line above for the copy this plan runs from, one REST call.
plugin_note() {
  pn_have=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$here/../../package.json" 2>/dev/null | head -n 1)
  pn_rel=$(gh api repos/Pawper/sipnship-plugin/releases/latest --jq .tag_name 2>/dev/null | tr -d '\r' | sed 's/^plugin-//; s/^v//')
  plugin_behind_note "$pn_have" "$pn_rel"
}
