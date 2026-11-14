#!/bin/sh
# Read the approval for the latest proposal on the project's drive issue.
# Read-only: it prints the approved goals, or says there is nothing to do.
#
# The drive issue is the open issue labeled "drive". A proposal is a comment
# that starts with "Proposal". An approval is the newest comment after that
# proposal written by someone other than the proposer, whose first line is
# "all", "none", a list of numbers, or "all but" a list of numbers.
#
# Auto Drive: when the drive issue carries the label drive:auto, approval is
# standing. The latest proposal is approved whole, with no reply needed, and
# the last line says "approved by Auto Drive". Without the label, the
# proposal waits for a reply as above. The issue and its labels come from
# one REST call.
#
# "Start this round": a reply "Queue request: start-round by LOGIN" (the
# dashboard's button) approves the latest proposal whole, at once.
#
# One round at a time: while the latest started round on the drive issue
# (its sipnship-proposal marker) still has issues In progress, or a unit
# whose pull request is still open, approved
# dispatch goals wait and a "held:" line says so; landing, fixing and
# asking go ahead. Only the newest two pages of comments are read.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/approval.sh"
# Prints: the approved goal lines, one per line, then "approved by NAME"; or
# one line saying why there is nothing: no drive issue, no proposal, no
# reply yet, or a reply that approved nothing.
here=$(dirname "$0")
. "$here/drive-lib.sh"
. "$here/round-lib.sh"
. "$here/round-state-lib.sh"

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "nothing: gh is not available or not signed in"
  exit 0
fi

drive_line=$(gh api "$AUTO_DRIVE_QUERY" --jq "$AUTO_DRIVE_JQ" 2>/dev/null | tr -d '\r')
auto=$(auto_drive_state "$drive_line")
[ "$auto" != none ] || { echo "nothing: no open issue labeled drive"; exit 0; }
issue=${auto#* }
auto=${auto%% *}
count=$(printf '%s\n' "$drive_line" | head -n 1 | cut -f3)

me=$(gh api user --jq .login 2>/dev/null)
tab=$(printf '\t')
# The newest comments: the last two pages of 100, since GitHub lists oldest first.
comments=""
for page in $(comment_pages "$count"); do
  comments="${comments}$(gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100&page=$page" --jq '.[] | [.created_at, .user.login, (.body | gsub("\t"; " ") | gsub("\r"; ""))] | @tsv' 2>/dev/null)
"
done
comments=$(printf '%s\n' "$comments" | sed '/^$/d')
[ -n "$comments" ] || { echo "nothing: no proposal on issue $issue yet"; exit 0; }

proposal=""; proposal_at=""; reply=""; reply_by=""
printf '%s\n' "$comments" | while IFS="$tab" read -r at author body; do :; done
# Walk the comments in order; keep the last proposal and the last reply after it.
# A round published for the dashboard (publish-round.sh's marker) is a
# proposal too, one dispatch goal per unit, unless it only repeats the
# numbered proposal before it; a started round that shares an issue with the
# proposal is that proposal started, so no earlier reply approves it again.
state=$(printf '%s\n' "$comments" | awk -F'\t' -v me="$me" '
  function marker_goals(b,   j, s, out) {
    j = b; sub(/.*sipnship-proposal /, "", j); sub(/"held":.*/, "", j); out = ""
    while (match(j, /"issues":\[[0-9, ]*\]/)) {
      s = substr(j, RSTART + 10, RLENGTH - 11); gsub(/ /, "", s); gsub(/,/, " ", s)
      if (s != "") out = out "dispatch " s "\n"
      j = substr(j, RSTART + RLENGTH)
    }
    return out
  }
  function dispatched(lines,   n, a, i, s, m, w, k, t, x) {
    t = " "; n = split(lines, a, "\n")
    for (i = 1; i <= n; i++) {
      s = a[i]; sub(/^[0-9]+\. /, "", s)
      if (s !~ /^dispatch /) continue
      m = split(substr(s, 10), w, /[ \t]+/)
      for (k = 1; k <= m && w[k] ~ /^[0-9]+:?$/; k++) { x = w[k]; sub(/:$/, "", x); t = t x " "; if (x != w[k]) break }
    }
    return t
  }
  # A numbered proposal and the round published after it in the same tick:
  # the round names the dispatches, the proposal keeps every other goal
  # (drain, merge, fix, audit, release), renumbered.
  function merge_round(prop, gl,   n, a, i, line, s, out, c, m, g) {
    n = split(prop, a, "\n"); out = ""; c = 0
    for (i = 1; i <= n; i++) {
      line = a[i]; s = line
      if (line ~ /^[0-9]+\. /) {
        sub(/^[0-9]+\. /, "", s)
        if (s ~ /^dispatch /) continue
        line = (++c) ". " s
      }
      out = out (out == "" ? "" : "\n") line
    }
    m = split(gl, g, "\n")
    for (i = 1; i <= m; i++) if (g[i] != "") out = out "\n" (++c) ". " g[i]
    return out
  }
  function shares(a, b,   n, x, i) { n = split(a, x, " "); for (i = 1; i <= n; i++) if (index(b, " " x[i] " ")) return 1; return 0 }
  function within(a, b,   n, x, i) { n = split(a, x, " "); if (n == 0) return 0; for (i = 1; i <= n; i++) if (!index(b, " " x[i] " ")) return 0; return 1 }
  {
    body = $3
    gsub(/\\n/, "\n", body)
    if (index(body, "sipnship-proposal {")) {
      goals = marker_goals(body); named = dispatched(goals)
      if (index(body, "\"status\":\"started\"")) {
        if (proposal != "" && shares(named, pissues)) { proposal = ""; pissues = " "; reply = ""; by = "" }
        next
      }
      if (goals != "" && proposal != "" && !frommarker && !within(named, pissues)) {
        proposal = merge_round(proposal, goals); pissues = named; at = $1; reply = ""; by = ""
        next
      }
      if (goals != "" && !(proposal != "" && within(named, pissues))) {
        frommarker = 1
        proposal = "Proposal: the round published on the drive issue"; c = 0
        n = split(goals, g, "\n"); for (i = 1; i <= n; i++) if (g[i] != "") proposal = proposal "\n" (++c) ". " g[i]
        pissues = named; at = $1; reply = ""; by = ""
      }
      next
    }
    if (body ~ /^Proposal/) { frommarker = 0; proposal = body; pissues = dispatched(body); at = $1; reply = ""; by = ""; next }
    # The other requests and answers left here are not a reply to the proposal (work-requests.sh reads them).
    if (body ~ /^Queue (request: (start-next|start-now|hold-agent|land-next|land-now|deploy-now) ?|answer: )/) next
    if (proposal != "" && $2 != me) { first = body; sub(/\n.*/, "", first); reply = first; by = $2 }
  }
  END {
    if (proposal == "") { print "noproposal"; exit }
    if (reply == "") print "noreply"
    else print "reply\t" by "\t" reply
    print proposal
  }')

case "$state" in
  noproposal) echo "nothing: no proposal on issue $issue yet"; exit 0 ;;
esac
head1=$(printf '%s\n' "$state" | head -n 1)
proposal=$(printf '%s\n' "$state" | tail -n +2)
started_by=""
[ "$head1" != noreply ] && started_by=$(start_request "$(printf '%s' "$head1" | cut -f3)")
if [ -n "$started_by" ]; then
  # "Start this round" from the dashboard: the whole proposal, now.
  reply=all; reply_by="$started_by, with Start this round"
elif [ "$auto" = on ]; then
  # Standing approval: the whole proposal, whatever any reply said.
  reply=all; reply_by="Auto Drive"
elif [ "$head1" = noreply ]; then
  echo "nothing: the latest proposal on issue $issue has no reply yet"; exit 0
else
  reply_by=$(printf '%s' "$head1" | cut -f2)
  reply=$(printf '%s' "$head1" | cut -f3)
fi

approved=$(approved_goals "$proposal" "$reply")
if [ -z "$approved" ]; then
  echo "nothing: $reply_by replied \"$reply\" and approved no goal"
  exit 0
fi
# One round at a time: while the latest started round still has issues in
# progress, its dispatches wait (one more REST call). "Start this round"
# starts it now, since the drive planned it against the running files.
if [ -z "$started_by" ] && printf '%s\n' "$approved" | grep -q '^dispatch '; then
  inprog=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=state:in-progress&per_page=100" --jq '.[].number' 2>/dev/null)
  # A started unit whose pull request is open is running too, whatever State its issues show (a held change leaves them Ready).
  open_prs=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[].number' 2>/dev/null | tr -d '\r')
  approved=$(hold_dispatch "$approved" "$(running_round "$comments" "$inprog" "$open_prs")")
fi
if [ -z "$(printf '%s\n' "$approved" | grep -v '^held: ')" ]; then
  printf '%s\n' "$approved" | sed 's/^held: /nothing: /'
  exit 0
fi
printf '%s\n' "$approved"
echo "approved by $reply_by"
