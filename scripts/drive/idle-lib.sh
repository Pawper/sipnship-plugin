#!/bin/sh
# An In progress issue with no agent, no open pull request and no commit on its branch is free to pick up again, never read
# as running (#2267). An agent that found nothing left to build once left an issue In progress for eight hours; the plan
# took it for a running unit and held what shared its files. Pure: text in, text out. Sourced by plan.sh.

# idle_in_progress FACTS PULLS BRANCHES NOW UNITS [GRACE [STARTED]]
# FACTS are board-now's lines; PULLS the plan's pull lines (NUMBER<TAB>HELD<TAB>CLOSES); BRANCHES "EPOCH<TAB>REF" for each
# branch's newest commit; NOW epoch seconds; UNITS the started round's units ("PR<TAB>ISSUES"), whose issues an agent was
# sent to. GRACE (default 900 seconds) is how long a freshly started issue has before its first branch or pull request:
# one touched more recently than that is still starting. STARTED is the epoch the round was started (round-state-lib's
# started_at); a unit's issue is given the same grace from STARTED, not forever: a unit is running only while it has
# evidence, and the grace covers only a unit just started, before its first branch or pull request can show (#2451).
# With no STARTED given (an older caller) a unit's issue is left alone, as before. Prints the numbers, one a line.
idle_in_progress() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v pulls="$2" -v branches="$3" -v now="$4" -v units="$5" -v grace="${6:-900}" -v started="${7:-}" '
    function epoch(iso,   cmd, t) { cmd = "date -u -d \"" iso "\" +%s 2>/dev/null"; cmd | getline t; close(cmd); return t + 0 }
    BEGIN {
      n = split(pulls, pl, "\n"); for (i = 1; i <= n; i++) { split(pl[i], f, "\t"); k = split(f[3], c, ","); for (j = 1; j <= k; j++) if (c[j] != "") pr[c[j]] = 1 }
      n = split(units, ul, "\n"); for (i = 1; i <= n; i++) { split(ul[i], f, "\t"); k = split(f[2], c, " "); for (j = 1; j <= k; j++) if (c[j] != "") un[c[j]] = 1 }
      nb = split(branches, bl, "\n")
    }
    $1 == "issue" && tolower($4) ~ /(^|,)state: ?in[- ]progress(,|$)/ {
      num = $2
      if (num in pr) next
      for (i = 1; i <= nb; i++) { split(bl[i], f, "\t"); if (f[2] ~ ("(^|[^0-9])" num "([^0-9]|$)") && f[2] !~ /^(origin\/)?fixside\//) next_issue = 1 }
      if (next_issue) { next_issue = 0; next }
      if (num in un) {
        if (started == "" || now - started < grace) next  # just started, with no evidence yet: give it the same grace stale_lines does
      } else if ($5 ~ /^[0-9][0-9][0-9][0-9]-/ && now - epoch($5) < grace) next
      print num
    }'
}

# idle_stale_lines FACTS IDLE [CLAIMED]: a `stale` line for each issue of IDLE (idle_in_progress' numbers, spaced or one
# a line) that nobody holds a claim on, so the plan sets it back to Ready and plays it as ready work in the same run (#2365):
#   stale<TAB>ISSUE<TAB>ready<TAB><TAB>TITLE<TAB>idle
# CLAIMED are the numbers (spaced) that hold a live claim, read by the caller; those stay as they are.
idle_stale_lines() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v OFS='\t' -v idle="$2" -v claimed="${3:-}" '
    BEGIN { n = split(idle, a, /[ \n]+/); for (i = 1; i <= n; i++) if (a[i] != "") d[a[i]] = 1; n = split(claimed, c, /[ \n]+/); for (i = 1; i <= n; i++) if (c[i] != "") cl[c[i]] = 1 }
    $1 == "issue" && ($2 in d) && !($2 in cl) { print "stale", $2, "ready", "", $3, "idle" }'
}

# idle_freed FACTS PULLS BRANCHES UNITS STALE [STARTED]: STALE with a line added for each idle issue holding no
# claim (and not already a line of it), so the plan sets it right. STARTED (round-state-lib's started_at) is passed
# on to idle_in_progress so a unit just started keeps its grace, past which it is judged by real evidence, in this
# same look, rather than waiting for a later tick (#2451). Reads the clock and one REST call per idle issue, plus
# one per distinct run a claim names, to tell a live claim from one whose run has already ended.
idle_freed() {
  if_now=$(idle_in_progress "$1" "$2" "$3" "$(date +%s)" "$4" "${IDLE_GRACE:-300}" "${6:-}" | tr "\n" " ")
  [ -n "$if_now" ] || { printf '%s\n' "$5"; return 0; }
  if_new=$(idle_stale_lines "$1" "$if_now" "$(idle_claimed "$if_now")" | awk -F'\t' -v s="$5" 'BEGIN { n = split(s, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, "\t"); seen[f[2]] = 1 } } !($2 in seen)')
  printf '%s\n%s\n' "$5" "$if_new" | sed '/^$/d'
}

# idle_claimed NUMBERS: the numbers (spaced) among NUMBERS that hold a live claim comment, one REST call each, only for
# the few issues already read as idle. A claim is a "Claim: TOKEN" comment under four hours old, never released, and
# whose run (a "Run:" second line, for a starter in GitHub Actions) GitHub does not report as completed: a claim is
# not live for hours on its own word when the run that made it has already ended (#2328, widened by #2451 to the
# plan's own look, not only claim-stale.sh's separate pass).
idle_claimed() {
  for ic_n in $1; do
    ic_c=$(gh api "repos/{owner}/{repo}/issues/$ic_n/comments?per_page=100&sort=created&direction=desc" --jq '[.[] | select(.body | test("^Claim(: | released: )"))] | reverse | .[] | [.id, (.created_at | fromdateiso8601), (.body | split("\n")[0]), ((.body | capture("(?m)^Run: (?<r>[0-9]+)$")?.r) // "")] | @tsv' 2>/dev/null)
    ic_ended=""
    for ic_r in $(claim_run_ids "$ic_c"); do
      if [ -n "${IDLE_OWN_RUN:-}" ] && [ "$ic_r" = "${IDLE_OWN_RUN:-}" ]; then ic_ended="$ic_ended
$ic_r"; continue; fi
      [ "$(gh api "repos/{owner}/{repo}/actions/runs/$ic_r" --jq .status 2>/dev/null)" != completed ] || ic_ended="$ic_ended
$ic_r"
    done
    [ -z "$ic_c" ] || [ -z "$(claim_live "$ic_c" "$(date +%s)" "${CLAIM_TTL:-14400}" "$ic_ended")" ] || printf '%s ' "$ic_n"
  done
}
