#!/bin/sh
# What the drive says about an issue that may be the owner's (functions only;
# owner_decision_hit is in drive-lib.sh). Sourced by plan.sh.

# owner_decision_context TEXT PHRASE
# The sentence of TEXT that holds PHRASE (ignoring case), on one line and cut
# at 160 characters, so a proposal's ask-owner line shows what matched in one
# look: a phrase such as "prices" also matches the verb. Nothing when absent.
owner_decision_context() {
  printf '%s\n' "$1" | tr '\t\r' '  ' | awk -v p="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" 'BEGIN { RS = "\001" } {
    t = $0; gsub(/\n+/, " ", t); n = split(t, s, /[.!?] +/)
    for (i = 1; i <= n; i++) if (index(tolower(s[i]), p)) { x = s[i]; sub(/^ +/, "", x); print substr(x, 1, 160); exit }
  }'
}

# owner_decision_declined NUM FILE
# "yes" when the drive already judged, on reading the issue in full, that it
# needs no ask (FILE holds one "NUM" or "NUM<TAB>why" per line): it is not
# proposed as an ask-owner again every tick.
owner_decision_declined() {
  [ -f "$2" ] || { echo no; return 0; }
  if tr -d '\r' < "$2" | cut -f1 | grep -qx "$1"; then echo yes; else echo no; fi
}

# owner_issue_fields NUM TEXT PHRASES
# The snapshot fields after "ready" for an issue: "yes<TAB>matched PHRASE in:
# SENTENCE" when TEXT holds an owner-decision phrase and the drive has not
# judged the issue to need no ask, else "no". A match is a candidate.
owner_issue_fields() {
  oi_hit=""
  [ -z "$3" ] || oi_hit=$(owner_decision_hit "$2" "$3")
  if [ -n "$oi_hit" ] && [ "$(owner_decision_declined "$1" .scratch/drive/no-ask.txt)" = no ]; then
    printf 'yes\tmatched "%s" in: %s\n' "$oi_hit" "$(owner_decision_context "$2" "$oi_hit")"
  else echo no; fi
}
