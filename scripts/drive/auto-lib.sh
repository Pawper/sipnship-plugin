#!/bin/sh
# Auto Drive and the drive issue: how the scripts find the open issue labeled drive and read its state.
# Sourced after drive-lib.sh by plan.sh, approval.sh, handoff.sh and work-requests.sh. Pure but for drive_issue_line.

# auto_drive_state LINE
# Auto Drive, read from the open issue labeled drive: LINE is that issue as
# one REST call gives it, "NUMBER<tab>LABEL,LABEL,..." (empty when there is
# no drive issue). Prints "on NUMBER" when the issue carries drive:auto,
# "off NUMBER" when it does not, and "none" when there is no drive issue.
# On is a standing approval: the drive starts the next round by itself when
# the current one lands. Off, it posts the proposal and waits for a reply.
auto_drive_state() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    $1 == "lookup-failed" { failed = 1; next }
    !seen && $1 ~ /^[0-9]+$/ {
      seen = 1; on = "off"
      n = split($2, l, ",")
      for (i = 1; i <= n; i++) if (l[i] == "drive:auto") on = "on"
      print on " " $1
    }
    END { if (!seen) print (failed ? "failed" : "none") }'
}

# drive_issue_line
# The drive issue as the one REST call gives it (AUTO_DRIVE_QUERY below), or the
# single word "lookup-failed" when the call itself failed, which auto_drive_state
# reads as "failed": a failed lookup is never taken for "there is no drive issue".
drive_issue_line() {
  di_out=$(gh api "$AUTO_DRIVE_QUERY" --jq "$AUTO_DRIVE_JQ" 2>/dev/null) || { echo lookup-failed; return 0; }
  printf '%s\n' "$di_out" | tr -d '\r'
}

# auto_line STATE
# The plan's last proposal line about Auto Drive, from auto_drive_state's
# output: what the round does with the proposal.
auto_line() {
  case "$1" in
    on\ *) printf 'auto drive: on (issue %s); approval is standing, so pursue the proposal once the current round has landed\n' "${1#on }" ;;
    off\ *) printf 'auto drive: off (issue %s); post the proposal on the drive issue and wait for a reply\n' "${1#off }" ;;
    failed) printf 'auto drive: not known; the lookup of the drive issue failed (it may still exist), so try the round again or ask in the session\n' ;;
    *) printf 'auto drive: off; there is no open issue labeled drive, so ask in the session\n' ;;
  esac
}

# The one REST call that reads it: the open issue labeled drive, its number,
# its labels and its comment count, in the shape auto_drive_state reads
# (the count, a third field, tells approval.sh which pages are newest).
AUTO_DRIVE_QUERY='repos/{owner}/{repo}/issues?labels=drive&state=open&per_page=1'
AUTO_DRIVE_JQ='.[0] // empty | [(.number | tostring), ([.labels[].name] | join(",")), (.comments | tostring)] | @tsv'
