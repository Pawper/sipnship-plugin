#!/bin/sh
# Pure helpers for claiming an issue before an agent starts on it, so one issue has one agent
# (specs/023-drive-on-work). Nothing here runs git or gh; every function takes text and prints text.
#
# A claim is a comment on the issue whose first line is "Claim: TOKEN"; "Claim released: TOKEN"
# ends it. GitHub cannot set a label only when it is unset, but it numbers comments in the order it
# received them, so of the live claims on one issue the lowest comment number wins, and a starter
# that finds its own claim is not the lowest stands down. Every starter (the scheduled drive, the
# wake, a Start now press) claims through claim.sh, so they all read the same line.

# claim_busy_reason ISSUE PULLS BRANCHES [PR_BRANCHES]
# Why an issue already has work: an open pull request that closes it, or a branch named for it whose
# work has not ended. PULLS are "NUMBER<TAB>CLOSES" lines (issue numbers comma separated), BRANCHES
# branch names one a line. PR_BRANCHES are "HEAD<TAB>STATE" lines, one per pull request of any state
# (open or closed, a squash merge included), for every branch git lists; with none given (or a
# branch no pull request of PR_BRANCHES names), a branch is read as busy, as before (#2259). A branch
# named for the issue is a real claim only while a pull request on it is still open: once its only
# pull requests have all ended (merged or closed with no squash commit main lacks), the branch is
# free, whatever it is named, since a squash merge leaves main with every commit the branch had.
# Prints one plain line, or nothing when the issue is free.
claim_busy_reason() {
  cb_pr=$(printf '%s\n' "$2" | tr -d '\r' | awk -F'\t' -v n="$1" '{ k = split($2, a, ","); for (i = 1; i <= k; i++) if (a[i] == n) { print $1; exit } }')
  [ -z "$cb_pr" ] || { printf 'an open pull request (#%s) already carries it\n' "$cb_pr"; return 0; }
  cb_br=$(printf '%s\n' "$3" | tr -d '\r' | sed 's#^refs/heads/##; s#^origin/##' | awk -v n="$1" '$0 == "issue-" n || index($0, "issue-" n "-") == 1 || $0 == "fix-" n { print; exit }')
  [ -z "$cb_br" ] || {
    cb_ended=$(printf '%s\n' "${4:-}" | tr -d '\r' | awk -F'\t' -v b="$cb_br" '
      $1 == b { seen = 1; if ($2 == "open") live = 1 }
      END { print (seen && !live) ? "yes" : "no" }')
    [ "$cb_ended" = yes ] || printf 'a branch (%s) already works it\n' "$cb_br"
  }
}

# claim_live COMMENTS NOW TTL
# COMMENTS are "ID<TAB>EPOCH<TAB>BODY" lines (BODY's first line only), oldest first. Prints the
# live claims, "ID<TAB>TOKEN" one a line: made within TTL seconds of NOW and not released.
claim_live() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v ttl="$3" '
    { b = $3 }
    b ~ /^Claim released: / { t = b; sub(/^Claim released: /, "", t); sub(/[ \t].*/, "", t); rel[t] = 1; next }
    b ~ /^Claim: / { t = b; sub(/^Claim: /, "", t); sub(/[ \t].*/, "", t); id[++n] = $1; tok[n] = t; at[n] = $2 }
    END { for (i = 1; i <= n; i++) if (!(tok[i] in rel) && now - at[i] <= ttl) print id[i] "\t" tok[i] }'
}

# claim_winner COMMENTS NOW TTL
# The token that holds the issue: the live claim with the lowest comment number. Nothing when none.
claim_winner() {
  claim_live "$1" "$2" "$3" | sort -n | head -n 1 | cut -f2
}

# claim_ended COMMENTS PUSH_EPOCH
# "yes" when the agent that held an issue has ended: it made at least one claim, every claim was released, and the
# last release came at or after PUSH_EPOCH (the change's last push), so nobody is on the change any more and it
# needs no half hour of waiting. "no" otherwise, and for a claim still held or no claim at all. COMMENTS are
# claim_live's lines, "ID<TAB>EPOCH<TAB>BODY".
claim_ended() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v push="$2" '
    { b = $3 }
    b ~ /^Claim released: / { t = b; sub(/^Claim released: /, "", t); sub(/[ \t].*/, "", t); rel[t] = 1; if ($2 + 0 > last) last = $2 + 0; next }
    b ~ /^Claim: / { t = b; sub(/^Claim: /, "", t); sub(/[ \t].*/, "", t); tok[++n] = t }
    END {
      if (n == 0 || push !~ /^[0-9]+$/ || last < push + 0) { print "no"; exit }
      for (i = 1; i <= n; i++) if (!(tok[i] in rel)) { print "no"; exit }
      print "yes"
    }'
}
