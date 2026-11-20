#!/bin/sh
# A change made for the owner's read is held while its issue waits on the owner (#2030), label or not.
# Sourced by the merge queue, the drive's approval step, scripts/state.sh and the nightly audit; the
# pure helper is text in and text out, the two readers use REST (gh api), never GraphQL.

# prs_closing_waiting PAIRS WAITING
# PAIRS is one "PR<TAB>BODY" line a pull request (BODY on one line); WAITING the numbers of the issues
# waiting on the owner, one per line. Prints "PR<TAB>ISSUE" for each pull request whose body closes
# (Closes, Fixes or Resolves #N, any case) one of them, ISSUE being the first that waits.
prs_closing_waiting() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v waiting="$2" '
    BEGIN { n = split(waiting, w, "\n"); for (i = 1; i <= n; i++) { gsub(/[ \t\r#]/, "", w[i]); if (w[i] != "") wait[w[i]] = 1 } }
    NF >= 2 {
      body = tolower($2)
      while (match(body, /(close[sd]?|fix(e[sd])?|resolve[sd]?):? #[0-9]+/)) {
        ref = substr(body, RSTART, RLENGTH); sub(/.*#/, "", ref)
        if (ref in wait) { print $1 "	" ref; break }
        body = substr(body, RSTART + RLENGTH)
      }
    }'
}

# waiting_issue_numbers: the open issues waiting on the owner, one number per line (either label form).
waiting_issue_numbers() {
  gh api "repos/{owner}/{repo}/issues?state=open&per_page=100" --paginate \
    --jq '.[] | select(.pull_request | not) | select([.labels[].name | ascii_downcase | test("^state: ?waiting-on-owner$")] | any) | .number' 2>/dev/null | tr -d '\r'
}

# open_pr_pairs: every open pull request as "NUMBER<TAB>HOLD<TAB>BODY", HOLD being held or free (a queue:hold or
# hold label, or a "Queue: hold" line), BODY on one line.
open_pr_pairs() {
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --paginate --jq '.[] | [.number, ((([.labels[].name | ascii_downcase] | (index("queue:hold") // index("hold"))) != null) or ((.body // "") | test("(^|\n)[ \t]*Queue:[ \t]*hold"; "i")) | if . then "held" else "free" end), ((.body // "") | gsub("[\r\n]+"; " "))] | @tsv' 2>/dev/null | tr -d '\r'
}

# open_pr_body_only_holds: the open pull requests whose body says "Queue: hold" but which carry no hold label,
# one number per line. The queue holds them anyway; the audit names them so the label is put right.
open_pr_body_only_holds() {
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --paginate --jq '.[] | select(((.body // "") | test("(^|\n)[ \t]*Queue:[ \t]*hold"; "i")) and (([.labels[].name | ascii_downcase] | (index("queue:hold") // index("hold"))) == null)) | .number' 2>/dev/null | tr -d '\r'
}

# hold_prs_for_issue ISSUE
# Puts queue:hold on every open pull request that closes ISSUE and has no hold yet, and says each in one
# line. state.sh calls it in the same step that sets the issue to waiting on the owner.
hold_prs_for_issue() {
  hp_pairs=$(open_pr_pairs | awk -F'\t' '$2 == "free" { print $1 "\t" $3 }')
  for hp_pr in $(prs_closing_waiting "$hp_pairs" "$1" | cut -f1); do
    if gh api -X POST "repos/{owner}/{repo}/issues/$hp_pr/labels" -f 'labels[]=queue:hold' >/dev/null 2>&1; then
      echo "Pull request #$hp_pr closes #$1, which now waits on you: queue:hold is on it, so it is not merged unread."
    else
      echo "Pull request #$hp_pr closes #$1, which now waits on you: queue:hold could not be set; set it by hand." >&2
    fi
  done
}
