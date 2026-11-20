#!/bin/sh
# For the nightly audit: every open pull request that should be held and carries no hold label, one line each.
#  - its issue waits on the owner: "#PR: closes #N, which waits on you, and has no queue:hold."
#  - its body says "Queue: hold": "#PR: its body says Queue: hold, and it has no queue:hold label."
# Such a change is waiting for the owner's read; the queue reads the line, but the label keeps every other
# reader honest. REST only; prints nothing when all is well or GitHub cannot be asked. Needs gh signed in.
here=$(dirname "$0")
. "$here/waiting-hold-lib.sh"
for ah_pr in $(open_pr_body_only_holds); do
  printf '#%s: its body says Queue: hold, and it has no queue:hold label.\n' "$ah_pr"
done
waiting=$(waiting_issue_numbers)
[ -n "$waiting" ] || exit 0
free=$(open_pr_pairs | awk -F'\t' '$2 == "free" { print $1 "\t" $3 }')
[ -n "$free" ] || exit 0
prs_closing_waiting "$free" "$waiting" | awk -F'\t' '{ printf "#%s: closes #%s, which waits on you, and has no queue:hold.\n", $1, $2 }'
exit 0
