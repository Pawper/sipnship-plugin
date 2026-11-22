#!/bin/sh
# A closed issue is never a running unit and never something another issue waits on (#2198). Closing does not always take
# its State label off, and a board read can still list an issue a minute after it closed, so the drive asks whether an
# issue is open before it reads its label. Sourced by plan.sh, approval.sh and closed-labels.sh.
# ISSUE_STATE_CMD (tests) names a command that prints an issue's state for the number it is given.

# issue_state_of N: open, closed, or nothing when GitHub cannot say (one REST call).
issue_state_of() {
  if [ -n "${ISSUE_STATE_CMD:-}" ]; then $ISSUE_STATE_CMD "$1"; return; fi
  gh api "repos/{owner}/{repo}/issues/$1" --jq .state 2>/dev/null | tr -d '\r'
}

# closed_among NUMBERS: the numbers (one a line or space separated) that are closed. One that cannot be read is not closed.
closed_among() {
  for ca_n in $(printf '%s\n' "$1" | tr -d '\r'); do
    if [ "$(issue_state_of "$ca_n")" = closed ]; then printf '%s\n' "$ca_n"; fi
  done
  return 0
}

# facts_without_closed FACTS: the board facts without the lines of an In progress issue that has closed, so the rest of the
# plan reads the board as it is: nothing running, nothing waiting on it. Only In progress issues are asked about (a few calls).
facts_without_closed() {
  fc_gone=""
  for fc_n in $(printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 == "issue" && tolower($4) ~ /(^|,)state: ?in[- ]progress(,|$)/ { print $2 }'); do
    if [ "$(issue_state_of "$fc_n")" = closed ]; then fc_gone="$fc_gone $fc_n"; fi
  done
  [ -n "$fc_gone" ] || { printf '%s\n' "$1"; return 0; }
  # Closing takes the State label off: do it now for the ones met here, unless the plan runs dry.
  if [ "${PLAN_PUBLISH:-}" != no ]; then for fc_n in $fc_gone; do closed_unlabel "$fc_n" >&2; done; fi
  printf '%s\n' "$1" | awk -F'\t' -v gone="$fc_gone" 'BEGIN { n = split(gone, a, " "); for (i = 1; i <= n; i++) g[a[i]] = 1 } !($1 == "issue" && ($2 in g))'
}

# closed_labels_json LABELS: LABELS (one a line) with every State label dropped, as the body of the labels call. A closed issue
# carries none: closed is what says it is done.
closed_labels_json() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    NF && tolower($0) !~ /^state: ?/ { out = out (out == "" ? "" : ",") q($0) }
    END { print "{\"labels\":[" out "]}" }'
}

# closed_unlabel N: take the State label off a closed issue (REST); says what it did, in one line.
closed_unlabel() {
  cu_labels=$(gh api "repos/{owner}/{repo}/issues/$1" --jq '.labels[].name' 2>/dev/null | tr -d '\r')
  closed_labels_json "$cu_labels" | gh api -X PUT "repos/{owner}/{repo}/issues/$1/labels" --input - >/dev/null 2>&1 \
    && echo "closed: #$1 is closed, so its State label is off." \
    || echo "closed: could not take the State label off #$1."
}

# closed_state_labels: the closed issues that still carry In progress, Ready, Waiting on owner or Blocked, "NUMBER<TAB>LABEL"
# a line, from the closed issue list (one REST call per label, newest first; none to read means nothing printed).
closed_state_labels() {
  for csl_l in "state:in-progress" "state:ready" "state:waiting-on-owner" "state:blocked" "state: in progress" "state: ready" "state: waiting on owner" "state: blocked"; do
    gh api -X GET "repos/{owner}/{repo}/issues" -f state=closed -f labels="$csl_l" -f per_page=100 --jq '.[] | select(.pull_request | not) | .number' 2>/dev/null | tr -d '\r' | sed "s/\$/	$csl_l/" | sed '/^	/d'
  done
}
