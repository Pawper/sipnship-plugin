#!/bin/sh
# Pure helpers for the drive's wake (specs/025-drive-wake): a workflow on
# a runner of its own runs one drive tick when a round's last pull request has
# landed or a start was asked for. Nothing here runs git or gh.

# wake_decision APPROVAL_OUTPUT [REQUESTS_OUTPUT]
# APPROVAL_OUTPUT is what approval.sh printed; REQUESTS_OUTPUT, when given, is
# what work-requests.sh printed (the Start next, Start now and hold requests
# the drive still owes an answer, one a line). Prints "start<TAB>N goals" when
# approval names at least one approved goal, "start<TAB>N requests" when only
# requests are owed, and "nothing<TAB>REASON" otherwise (approval.sh's own
# "nothing:" line, or "held:" lines only), so a wake with nothing to do ends
# at once and spends no model.
wake_decision() {
  _wk_req=$(printf '%s\n' "${2:-}" | tr -d '\r' | awk 'NF > 0 && !/^nothing/ { n++ } END { print n + 0 }')
  printf '%s\n' "$1" | tr -d '\r' | awk -v req="$_wk_req" '
    /^nothing: / { why = substr($0, 10); next }
    /^held: / { if (why == "") why = substr($0, 7); next }
    /^approved by / { next }
    NF > 0 { goals++ }
    END {
      if (goals > 0) printf "start\t%d goal%s\n", goals, (goals == 1 ? "" : "s")
      else if (req > 0) printf "start\t%d request%s\n", req, (req == 1 ? "" : "s")
      else printf "nothing\t%s\n", (why == "" ? "nothing approved" : why)
    }'
}

# approved_not_planned PLAN APPROVAL
# PLAN is what plan.sh printed this tick, APPROVAL what approval.sh printed. The
# issues (one unit a line, as "12 14") of the approved dispatch goals the plan no
# longer prints: they were approved from an older posted proposal, so the tick
# starts none of them and says so (#2104). Nothing when every approved dispatch
# is one the plan prints, or when there is no approved dispatch.
approved_not_planned() {
  { printf '%s\n' "$1" | tr -d '\r' | sed 's/^[0-9]*\. //' | awk -F'\t' '$1 ~ /^dispatch [0-9]/ { print "P " substr($1, 10) }'
    printf '%s\n' "$2" | tr -d '\r' | sed 's/^[0-9]*\. //' | awk -F'\t' '$1 ~ /^dispatch [0-9]/ { print "A " substr($1, 10) }'; } \
    | awk '{ k = substr($0, 3); gsub(/[ ]+/, " ", k); sub(/ $/, "", k); if ($1 == "P") planned[k] = 1; else if (!(k in planned) && !(k in said)) { said[k] = 1; print k } }'
}

# wake_event_wanted EVENT BODY
# Which events may start a tick. "yes" for a dispatch (by hand or sent by the
# service), a finished queue drain, and a comment on the drive issue that is
# dashboard's start form (`Queue request: start-round`, `start-now`,
# `start-next` or `hold-agent`, the requests the drive answers), and the
# builder's answer to an ask on any issue (a `Builder answer: #N` line), which
# reshapes the proposal at once (#2101); "no" for any other comment, a landing
# request included (the queue's own wake hears it).
wake_event_wanted() {
  case "$1" in
    workflow_dispatch|repository_dispatch|workflow_run) echo yes ;;
    issue_comment)
      case "$2" in 'Queue request: start-round'*|'Queue request: start-now'*|'Queue request: start-next'*|'Queue request: hold-agent'*|*'Builder answer: #'*) echo yes ;; *) echo no ;; esac ;;
    *) echo no ;;
  esac
}

# wake_unit_state NOW DISPATCHED_EPOCH BRANCH PR COMMIT LIVE [GRACE_SECONDS]
# What a started unit really is, so a dashboard dot is never blue for an agent
# that made nothing (specs/025-drive-wake, "A woken tick's agents outlive it").
# BRANCH, PR and COMMIT are "yes" or "no" (its branch exists, a pull request is
# open or landed, a commit is on the branch); LIVE is "yes" while an agent
# session for the unit is still running. Prints:
#   working   a branch, commit or pull request exists: "agent on it" is true
#   starting  nothing made yet, but it is young (GRACE_SECONDS, default 600)
#             or its agent is still running; the dashboard says "starting"
#   restart   nothing made, old, and no agent running: it died; the unit goes
#             back to Ready, first in the round
wake_unit_state() {
  if [ "$3" = yes ] || [ "$4" = yes ] || [ "$5" = yes ]; then echo working; return 0; fi
  case "$2" in ''|*[!0-9]*) echo starting; return 0 ;; esac
  if [ $(( $1 - $2 )) -lt "${7:-600}" ] || [ "$6" = yes ]; then echo starting; else echo restart; fi
}

# wake_units_read NOW UNITS [GRACE_SECONDS]
# UNITS: one started unit a line,
# "NUMBER<TAB>DISPATCHED_EPOCH<TAB>BRANCH<TAB>PR<TAB>COMMIT<TAB>LIVE".
# Prints "NUMBER<TAB>STATE" for each, STATE as wake_unit_state says.
wake_units_read() {
  printf '%s\n' "$2" | tr -d '\r' | while IFS='	' read -r wu_n wu_t wu_b wu_p wu_c wu_l; do
    [ -n "$wu_n" ] || continue
    printf '%s\t%s\n' "$wu_n" "$(wake_unit_state "$1" "$wu_t" "$wu_b" "$wu_p" "$wu_c" "$wu_l" "${3:-}")"
  done
}

# wake_restart_comment
# The one line left on an issue sent back to Ready because its agent died.
wake_restart_comment() {
  echo "Restarted: the agent for this stopped before it made a branch, so nothing was lost. It is back in Ready and starts first in the next round."
}

# wake_agents_left COUNT
# The tick's closing line: how many agents it left running when it ended.
wake_agents_left() {
  case "$1" in
    0|'') echo "Left running when this tick ended: no agents." ;;
    1) echo "Left running when this tick ended: 1 agent." ;;
    *) echo "Left running when this tick ended: $1 agents." ;;
  esac
}

# dead_round_issues NOW STARTED_EPOCH BRANCHES UNITS [MINUTES]
# A round counts a unit as running only while there is evidence of it
# (specs/025-drive-wake, "A round that left nothing"). UNITS is what
# started_units printed ("PR<TAB>ISSUES", one unit a line); BRANCHES is every
# branch name on the remote, one a line. Prints the issues, space separated,
# of the units that left nothing for MINUTES (default 20) after the round
# started: no pull request and no branch named for any of their issues
# ("issue-N" or "issue-N-..."). Those units are dead, and their issues go
# back to Ready first. Nothing while the round is young or has evidence.
dead_round_issues() {
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $1 - $2 )) -ge $(( ${5:-20} * 60 )) ] || return 0
  printf '%s\n' "$4" | tr -d '\r' | awk -F'\t' -v br="$3" '
    BEGIN { n = split(br, a, "\n"); for (i = 1; i <= n; i++) { gsub(/\r/, "", a[i]); sub(/^(refs\/heads\/|origin\/)/, "", a[i]); if (a[i] != "") b[a[i]] = 1 } }
    $1 == "" && $2 != "" {
      m = split($2, is, " "); live = 0
      for (i = 1; i <= m && !live; i++) for (k in b) if (k == "issue-" is[i] || index(k, "issue-" is[i] "-") == 1) { live = 1; break }
      if (!live) for (i = 1; i <= m; i++) out = out (out == "" ? "" : " ") is[i]
    }
    END { if (out != "") print out }'
}

# dead_round_comment
# The one line left on an issue whose round left nothing, and said in the round's report.
dead_round_comment() {
  echo "Restarted: the round that took this made no branch, commit or pull request in twenty minutes, so nothing was lost. It is back in Ready and starts first in the next round."
}
