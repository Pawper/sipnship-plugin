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

# owner_decision_open TITLE BODY PHRASES
# The first owner-decision phrase the issue leaves open, or nothing. A phrase
# in passing is not a decision: it counts only as a whole word in the title,
# or in a sentence the issue marks as a question (it ends in "?" or says
# "question:" or "decision:"), and never when the body already holds an
# answer from the owner ("Builder answer:" or "Owner answer:").
owner_decision_open() {
  case "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" in *"builder answer:"*|*"owner answer:"*) return 0 ;; esac
  printf '%s\n' "$3" | tr -d '\r' | while IFS= read -r odo_p; do
    [ -n "$odo_p" ] || continue
    if owner_phrase_in_open "$1" "$odo_p" title || owner_phrase_in_open "$2" "$odo_p" body; then
      printf '%s\n' "$odo_p"; break
    fi
  done
}

# owner_phrase_in_open TEXT PHRASE title|body
# Success when PHRASE stands as a whole word in TEXT (title) or in a marked
# sentence of it (body).
owner_phrase_in_open() {
  printf '%s\n' "$1" | tr '\t\r' '  ' | awk -v p="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" -v mode="$3" 'BEGIN { RS = "\001"; found = 0 } {
    t = tolower($0); gsub(/\n+/, " ", t)
    if (mode == "title") { if (word(t)) found = 1; exit }
    while (length(t) > 0) {
      if (!match(t, /[.!?]+( +|$)/)) { s = t; end = ""; t = "" }
      else { s = substr(t, 1, RSTART - 1); end = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
      if (index(end, "?") || s ~ /(question|decision): / || s ~ /^ *(question|decision)s?:/) { if (word(s)) { found = 1; exit } }
    }
  } END { exit found ? 0 : 1 }
  function word(x,   i, b, a, rest, off) {
    off = 0; rest = x
    while ((i = index(rest, p)) > 0) {
      b = (off + i > 1) ? substr(x, off + i - 1, 1) : " "
      a = substr(x, off + i + length(p), 1); if (a == "") a = " "
      if (b !~ /[a-z0-9]/ && a !~ /[a-z0-9]/) return 1
      off += i; rest = substr(x, off + 1)
    }
    return 0
  }'
}

# owner_issue_fields NUM TITLE BODY PHRASES
# The snapshot fields after "ready" for an issue: "yes<TAB>matched PHRASE in:
# SENTENCE" when the issue leaves an owner-decision phrase open (see
# owner_decision_open) and the drive has not judged it to need no ask, else
# "no". A match is a candidate.
owner_issue_fields() {
  oi_hit=""
  [ -z "$4" ] || oi_hit=$(owner_decision_open "$2" "$3" "$4")
  if [ -n "$oi_hit" ] && [ "$(owner_decision_declined "$1" .scratch/drive/no-ask.txt)" = no ]; then
    printf 'yes\tmatched "%s" in: %s\n' "$oi_hit" "$(owner_decision_context "$2 $3" "$oi_hit")"
  else echo no; fi
}
