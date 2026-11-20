#!/bin/sh
# For the nightly audit: every open pull request whose issue waits on the owner and carries no hold,
# one line each, "#PR: closes #N, which waits on you, and has no queue:hold." Such a change is waiting
# for the owner's read; with no hold the queue could merge it unread. REST only; prints nothing when
# all is well or GitHub cannot be asked. Needs gh signed in for the repository.
here=$(dirname "$0")
. "$here/waiting-hold-lib.sh"
waiting=$(waiting_issue_numbers)
[ -n "$waiting" ] || exit 0
free=$(open_pr_pairs | awk -F'\t' '$2 == "free" { print $1 "\t" $3 }')
[ -n "$free" ] || exit 0
prs_closing_waiting "$free" "$waiting" | awk -F'\t' '{ printf "#%s: closes #%s, which waits on you, and has no queue:hold.\n", $1, $2 }'
exit 0
