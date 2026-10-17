#!/bin/sh
# Pure helpers for the project-drive skill. Nothing here runs git or gh;
# plan.sh gathers a snapshot of the project and these turn it into a
# proposal, and a person's reply into the approved part of it. Every
# function takes text and prints text; tests/run.sh covers each with a
# fixture under tests/fixtures/.
#
# A snapshot is one line per fact, tab separated:
#   pr      NUMBER  TITLE  ci(green|red|pending)  merge(mergeable|conflicting|unknown)  class(app|other)
#   issue   NUMBER  TITLE  state(ready|in-progress|waiting-on-owner|blocked)  owner(yes|no)
#   audit   TEXT            the audit issue's latest comment, one line
#   red     NUMBER          an open red-main issue
#   queue   recent|stale|none

# propose_round SNAPSHOT RUNNERS MAX_AGENTS
# Print the goals this round proposes, one per line, in the order they
# would be pursued: land what is green (as one batch when more than two app
# PRs are green), fix what is red, ask about what is the owner's, start
# ready issues up to the smaller of RUNNERS and MAX_AGENTS less what is in
# progress, set right what the audit flagged, restart a stale queue. The
# last line is a "stop" line saying why the round would end. Nothing here
# is done; a person approves first.
propose_round() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v runners="${2:-2}" -v max_agents="${3:-4}" '
    $1 == "pr" && $4 == "green" && $5 == "mergeable" { green[++g] = $2; if ($6 != "other") appgreen++ }
    $1 == "pr" && $4 == "red" { red[++r] = $2 "\t" $3 }
    $1 == "pr" && ($4 == "pending" || $5 == "conflicting" || $5 == "unknown") && $4 != "red" { waiting_pr++ }
    $1 == "issue" && $4 == "ready" && $5 == "yes" { ask[++k] = $2 "\t" $3 }
    $1 == "issue" && $4 == "ready" && $5 != "yes" { ready[++n] = $2 "\t" $3 }
    $1 == "issue" && $4 == "in-progress" { inprogress++ }
    $1 == "issue" && $4 == "waiting-on-owner" { onowner++ }
    $1 == "audit" && $2 != "" { audit = $2 }
    $1 == "red" { redmain = $2 }
    $1 == "queue" { queue = $2 }
    END {
      acted = 0
      if (g > 2 && appgreen > 2) {
        line = "merge-batch"; for (i = 1; i <= g; i++) line = line " " green[i]
        print line; acted++
      } else {
        for (i = 1; i <= g; i++) { print "merge " green[i]; acted++ }
      }
      for (i = 1; i <= r; i++) { print "fix-pr " red[i]; acted++ }
      for (i = 1; i <= k; i++) { print "ask-owner " ask[i]; acted++ }
      slots = (runners < max_agents) ? runners : max_agents
      slots -= inprogress
      dispatched = 0
      for (i = 1; i <= n && dispatched < slots; i++) { print "dispatch " ready[i]; dispatched++; acted++ }
      if (n > dispatched) print "defer " (n - dispatched) " ready issue(s): no free runner this round"
      if (redmain != "") { print "fix-main " redmain; acted++ }
      if (audit != "") { print "audit " audit; acted++ }
      if (queue == "stale") { print "restart-queue"; acted++ }
      if (acted == 0) {
        if (onowner > 0 && n == 0) print "stop: everything left waits on a person"
        else if (waiting_pr > 0 || inprogress > 0) print "stop: work is in flight; nothing to propose until it lands"
        else print "stop: nothing to propose"
      } else {
        print "stop: proposal ready for approval"
      }
    }'
}

# number_proposal LINES
# Give each goal a number for a person to answer with: "1. merge-batch 41 42".
# The defer and stop lines are information, not goals, and stay unnumbered.
number_proposal() {
  printf '%s\n' "$1" | awk '
    NF == 0 { next }
    /^(defer|stop:)/ { print; next }
    { printf "%d. %s\n", ++n, $0 }'
}

# approved_goals NUMBERED REPLY
# NUMBERED is the output of number_proposal; REPLY is a person'\''s answer:
# "all", "none", a list of numbers ("1 3 4" or "1, 3, 4"), or "all but 2 3".
# Print the approved goal lines without their numbers, in proposal order.
# A reply that names nothing approves nothing.
approved_goals() {
  ag_reply=$(printf '%s' "$2" | tr 'A-Z' 'a-z' | tr -d '\r')
  printf '%s\n' "$1" | awk -v reply="$ag_reply" '
    BEGIN {
      mode = "list"
      if (reply ~ /^[ \t]*all[ \t]*but/) { mode = "allbut"; sub(/^[ \t]*all[ \t]*but/, "", reply) }
      else if (reply ~ /^[ \t]*all([ \t]|$)/) mode = "all"
      else if (reply ~ /^[ \t]*none([ \t]|$)/) mode = "none"
      gsub(/[^0-9]+/, " ", reply)
      c = split(reply, nums, " ")
      for (i = 1; i <= c; i++) if (nums[i] != "") picked[nums[i] + 0] = 1
    }
    /^[0-9]+\. / {
      n = $1 + 0
      text = $0; sub(/^[0-9]+\. /, "", text)
      if (mode == "all") print text
      else if (mode == "allbut" && !(n in picked)) print text
      else if (mode == "list" && (n in picked)) print text
    }'
}

# queue_is_stale MTIME NOW LAST_LINE
# "yes" when the newest queue log is older than two hours and its last line
# does not say the queue finished; "no" otherwise, including with no log.
queue_is_stale() {
  case "$1" in ''|*[!0-9]*) echo no; return 0 ;; esac
  case "$2" in ''|*[!0-9]*) echo no; return 0 ;; esac
  if [ $(( $2 - $1 )) -le 7200 ]; then echo no; return 0; fi
  case "$3" in *"queue done"*) echo no ;; *) echo yes ;; esac
}

# owner_decision_hit TEXT PHRASES
# PHRASES is one short phrase per line, the owner'\''s own list of what is
# always theirs. Print the first phrase that appears in TEXT, ignoring
# case, or nothing.
owner_decision_hit() {
  od_text=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  printf '%s\n' "$2" | tr -d '\r' | while IFS= read -r od_p; do
    [ -n "$od_p" ] || continue
    od_l=$(printf '%s' "$od_p" | tr 'A-Z' 'a-z')
    case "$od_text" in *"$od_l"*) printf '%s\n' "$od_p"; break ;; esac
  done
}

# trim_report TEXT PER_SECTION
# A report is headings (lines ending in a colon) with lines under each.
# Keep every heading; under each, keep at most PER_SECTION lines and say
# how many were cut.
trim_report() {
  printf '%s\n' "$1" | awk -v limit="$2" '
    /:$/ { flush(); print; count = 0; cut = 0; next }
    NF == 0 { next }
    { if (count < limit) { print; count++ } else cut++ }
    END { flush() }
    function flush() { if (cut > 0) printf "(and %d more)\n", cut; cut = 0 }'
}
