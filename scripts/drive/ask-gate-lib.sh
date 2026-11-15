#!/bin/sh
# The plan's mark-waiting goals, held to the ask rule before they are proposed.
# Sourced by plan.sh after round-lib.sh (mark_waiting_ok) and the project's
# scripts/ci/ask-lib.sh (ask_verdict, ask_fix, the one reader of an ask).

# mark_waiting_goals EXTRA VERDICTS
# EXTRA is digest_goals' lines; VERDICTS is "NUMBER<TAB>WORD" per issue, the
# word ask_verdict gave its latest ask. A "mark-waiting N" line stays only for
# an ask in the shape (mark_waiting_ok), and so runs without approval; any
# other becomes an "ask-fix N" line saying what to fix, so the state-label
# hook is never the first to refuse it. Other goals pass through.
mark_waiting_goals() {
  printf '%s\n' "$1" | tr -d '\r' | while IFS= read -r mw_l; do
    case "$mw_l" in
      "mark-waiting "*)
        mw_n=$(printf '%s' "$mw_l" | sed 's/^mark-waiting \([0-9]*\).*/\1/')
        mw_t=$(printf '%s' "$mw_l" | cut -f2 | sed 's/ (a question to the owner is open)$//')
        mw_v=$(printf '%s\n' "$2" | awk -F'\t' -v n="$mw_n" '$1 == n { print $2; exit }')
        if [ "$(mark_waiting_ok "$mw_v")" = yes ]; then printf '%s\n' "$mw_l"; continue; fi
        mw_f=$(ask_fix "$mw_v")
        [ -n "$mw_f" ] || mw_f='no ask in the shape (a question, numbered choices, one "Recommended.") is on it yet; the agent that wrote the question puts it in the shape'
        printf 'ask-fix %s\t%s (not marked waiting: %s)\n' "$mw_n" "$mw_t" "$mw_f" ;;
      '') ;;
      *) printf '%s\n' "$mw_l" ;;
    esac
  done
}

# ask_answered KINDS: "yes" when the builder's newest answer comes after the
# newest ask. KINDS is one letter a comment, oldest first, separated by
# spaces: q (an ask: it has a "Recommended." choice), a (a "Builder answer:"
# line, the fixed form answers.sh reads), - (anything else). An ask that
# follows an answer is a new question, so it is open again.
ask_answered() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) { if ($i == "q") q = i; if ($i == "a") a = i } } END { print (a > q) ? "yes" : "no" }'
}

# answered_for EXTRA: the numbers (one a line) of the mark-waiting issues in
# EXTRA whose newest ask has a builder's answer after it; REST, one call per
# such issue. An issue the ask was answered on is Ready on purpose, whatever
# a summary of its comments says.
answered_for() {
  for an_n in $(printf '%s\n' "$1" | sed -n 's/^mark-waiting \([0-9]*\).*/\1/p'); do
    an_k=$(gh api "repos/{owner}/{repo}/issues/$an_n/comments?per_page=100" --jq '[.[] | .body | gsub("\r"; "") | if test("(^|\n)[ \t]*Builder answer: #[0-9]+ choice [0-9]") then "a" elif test("Recommended\\.") then "q" else "-" end] | join(" ")' 2>/dev/null | tr -d '\r')
    if [ "$(ask_answered "$an_k")" = yes ]; then printf '%s\n' "$an_n"; fi
  done
  return 0
}

# held_answered_say PULL ISSUE: the plan's line for a held pull request whose
# ask on ISSUE has been answered. An answer that lets a held change land
# lifts the hold in the service when it is written (specs/022-asks), and the
# drive never changes the label itself; so a hold still there means the
# answer did not let it land, and it stays the builder's to release.
held_answered_say() {
  printf 'held: #%s is held for the builder, and the question on #%s has been answered. An answer that lets it land lifts the hold by itself; this one did not, so it stays held until the builder lets it land. The drive does not change the hold.\n' "$1" "$2"
}

# held_answered_lines PULLS: one held_answered_say line for each held pull
# request (PULLS are NUMBER<TAB>HELD<TAB>CLOSES, as stale_lines reads them)
# that closes an issue whose newest ask has been answered; REST, one call per
# such issue. A pull request is named once.
held_answered_lines() {
  printf '%s\n' "$1" | tr -d '\r' | while IFS="$(printf '\t')" read -r ha_pr ha_held ha_closes ha_rest; do
    [ "$ha_held" = yes ] || continue
    for ha_n in $(printf '%s' "$ha_closes" | tr ',' ' '); do
      ha_k=$(gh api "repos/{owner}/{repo}/issues/$ha_n/comments?per_page=100" --jq '[.[] | .body | gsub("\r"; "") | if test("(^|\n)[ \t]*Builder answer: #[0-9]+ choice [0-9]") then "a" elif test("Recommended\\.") then "q" else "-" end] | join(" ")' 2>/dev/null | tr -d '\r')
      if [ "$(ask_answered "$ha_k")" = yes ]; then held_answered_say "$ha_pr" "$ha_n"; break; fi
    done
  done
  return 0
}

# drop_waiting_goals EXTRA NUMBERS: EXTRA without the mark-waiting lines for
# the issues in NUMBERS (one a line, or space separated).
drop_waiting_goals() {
  printf '%s\n' "$1" | awk -v drop=" $(printf '%s' "$2" | tr '\n' ' ') " '
    /^mark-waiting [0-9]+/ { n = $2; sub(/\t.*/, "", n); if (index(drop, " " n " ")) next }
    { print }'
}

# unit_issues UNITS: the issue numbers of the started round's units (as
# started_units prints them), one a line; their agents are on them, so no
# stale ask of an earlier tick moves them to the owner.
unit_issues() {
  printf '%s\n' "$1" | awk -F'\t' 'NF >= 2 { n = split($2, a, " "); for (i = 1; i <= n; i++) print a[i] }'
}

# ask_verdicts_for EXTRA: "NUMBER<TAB>WORD" for each mark-waiting issue in
# EXTRA, from its comments (newest first, parted as ask_verdict reads them);
# REST, one call per such issue, and none when there are none.
ask_verdicts_for() {
  for av_n in $(printf '%s\n' "$1" | sed -n 's/^mark-waiting \([0-9]*\).*/\1/p'); do
    av_c=$(gh api "repos/{owner}/{repo}/issues/$av_n/comments?per_page=100" --jq "[.[].body] | reverse | join(\"\\n$ASK_NEXT\\n\")" 2>/dev/null | tr -d '\r')
    printf '%s\t%s\n' "$av_n" "$(printf '%s\n' "$av_c" | ask_verdict)"
  done
}

# quiet_ask_fixes EXTRA FACTS FILE
# An `ask-fix N` the drive already looked at and could do nothing about (FILE, one
# "N<TAB>UPDATED_AT" per line, written by ask-fix-seen.sh) is not a numbered goal on every
# tick: while the issue is as it was then (FACTS' updated time for N is the one in FILE) its
# line becomes a hold saying what it waits on. Another change to the issue proposes it again.
quiet_ask_fixes() {
  { [ ! -f "$3" ] || tr -d '\r' < "$3" | sed 's/^/S\t/'; printf '%s\n' "$2" | tr -d '\r' | sed 's/^/F\t/'; printf '%s\n' "$1" | sed 's/^/E\t/'; } | awk -F'\t' '
    $1 == "S" { seen[$2] = $3 }
    $1 == "F" && $2 == "issue" { upd[$3] = $6 }
    $1 == "E" && $2 ~ /^ask-fix [0-9]+$/ && (substr($2, 9) in seen) && seen[substr($2, 9)] == upd[substr($2, 9)] {
      t = $3; sub(/ \(not marked waiting:.*$/, "", t)
      printf "hold %s\t%s\tIts open question is not in the ask shape, and the drive could not put it there; it waits for your answer or for the issue to change\n", substr($2, 9), t; next }
    $1 == "E" && $2 != "" { print substr($0, 3) }'
}

# add_owner_goals ROUND EXTRA FACTS FILE
# What the digest adds to ROUND: an issue the proposal puts to the owner is not offered to an agent
# (owner_waiting_holds), an ask-fix already tried is quiet (quiet_ask_fixes), and the proposal is
# ready for approval only when a goal besides holds was added.
add_owner_goals() {
  ao_round=$(owner_waiting_holds "$1" "$2")
  ao_extra=$(quiet_ask_fixes "$2" "$3" "$4")
  # One hold line for an issue: a quiet ask-fix's own wins over the general one.
  if [ -n "$(printf '%s\n' "$ao_extra" | sed '/^$/d' | grep -v '^hold ')" ]; then
    printf '%s\n%s\n' "$ao_extra" "$ao_round" | awk '/^hold / { split($0, a, /[ \t]/); if (seen[a[2]]++) next } /^stop: (nothing to propose|everything left waits|work is in flight)/ { print "stop: proposal ready for approval"; next } { print }'
  else printf '%s\n%s\n' "$ao_extra" "$ao_round" | awk 'NF == 0 { next } /^hold / { split($0, a, /[ \t]/); if (seen[a[2]]++) next } { print }'; fi
}

# owner_waiting_holds ROUND EXTRA
# An issue the proposal itself puts to the owner (EXTRA's "ask-fix N" or
# "mark-waiting N": a question or a step only the owner can do) is not offered
# to an agent in the same proposal. Its number leaves ROUND's dispatch lines
# (a dispatch left with no issue goes), and a hold line says why, in the
# builder's words: "hold N<TAB>TITLE<TAB>WHY". Other lines pass through.
owner_waiting_holds() {
  ow_nums=$(printf '%s\n' "$2" | sed -nE 's/^(ask-fix|mark-waiting) ([0-9]+).*/\2/p' | tr '\n' ' ')
  [ -n "$ow_nums" ] || { printf '%s\n' "$1"; return 0; }
  printf '%s\n' "$1" | awk -F'\t' -v owner=" $ow_nums" '
    function flush(   i) { for (i = 1; i <= h; i++) print holds[i]; h = 0 }
    /^dispatch / {
      head = $1; rest = ""; for (i = 2; i <= NF; i++) rest = rest "\t" $i
      m = split(substr(head, 10), w, / +/); keep = ""; kept = 0
      for (k = 1; k <= m; k++) {
        if (w[k] == "") continue
        if (index(owner, " " w[k] " ")) holds[++h] = "hold " w[k] "\t" (m == 1 ? $2 : "") "\tWaits on your answer; not offered to an agent while it is open"
        else { keep = keep (keep == "" ? "" : " ") w[k]; kept++ }
      }
      if (kept > 0) print "dispatch " keep rest
      next
    }
    /^stop:/ { flush(); print; next }
    { print }
    END { flush() }'
}
