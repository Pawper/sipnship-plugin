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

# wake_event_wanted EVENT BODY
# Which events may start a tick. "yes" for a dispatch (by hand or sent by the
# service), a finished queue drain, and a comment on the drive issue that is
# dashboard's start form (`Queue request: start-round`, `start-now`,
# `start-next` or `hold-agent`, the requests the drive answers); "no" for any
# other comment, a landing request included (the queue's own wake hears it).
wake_event_wanted() {
  case "$1" in
    workflow_dispatch|repository_dispatch|workflow_run) echo yes ;;
    issue_comment)
      case "$2" in 'Queue request: start-round'*|'Queue request: start-now'*|'Queue request: start-next'*|'Queue request: hold-agent'*) echo yes ;; *) echo no ;; esac ;;
    *) echo no ;;
  esac
}
