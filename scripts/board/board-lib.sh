#!/bin/sh
# Pure helpers for the board digest. No git, no gh; text in, text out.
#
# FACTS is the output of hooks/scripts/board-now.sh: one line per open pull
# request or issue, with its last-updated time (pr column 8, issue column 5).
# A DIGEST is the saved summary, one line per item, tab separated:
#   NUMBER  KIND(issue|pr)  UPDATED_AT  BALL  NEXT  BLOCKER  SUMMARY
# UPDATED_AT is the item's last-updated time when the summary was written,
# so a summary is current exactly when that time still matches the board.
# BALL says who has it: owner, agent, reviewer, service or nobody.

# open_items FACTS
# Print "NUMBER<TAB>KIND<TAB>UPDATED_AT<TAB>TITLE" for every open item.
open_items() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    $1 == "pr" { printf "%s\tpr\t%s\t%s\n", $2, $8, $3 }
    $1 == "issue" { printf "%s\tissue\t%s\t%s\n", $2, $5, $3 }'
}

# changed_items FACTS DIGEST
# Print "NUMBER<TAB>KIND" for every open item whose summary is missing or
# was written at a different last-updated time. These are the only ones
# worth reading again.
changed_items() {
  open_items "$1" | awk -F'\t' -v digest="$2" '
    BEGIN { n = split(digest, d, "\n"); for (i = 1; i <= n; i++) { split(d[i], f, "\t"); if (f[1] != "") at[f[2] ":" f[1]] = f[3] } }
    { k = $2 ":" $1; if (!(k in at) || at[k] != $3 || $3 == "") printf "%s\t%s\n", $1, $2 }'
}

# digest_freshness FACTS DIGEST
# Print "CURRENT<TAB>TOTAL": how many open items have a current summary,
# and how many open items there are.
digest_freshness() {
  df_total=$(open_items "$1" | sed '/^$/d' | wc -l | tr -d ' ')
  df_changed=$(changed_items "$1" "$2" | sed '/^$/d' | wc -l | tr -d ' ')
  printf '%s\t%s\n' "$((df_total - df_changed))" "$df_total"
}

# merge_digest DIGEST NEW FACTS
# NEW is what the readers returned, one line per item:
#   "NUMBER | BALL | NEXT | BLOCKER | SUMMARY"
# Print the new digest: every line of DIGEST for an item that is still
# open, with the items in NEW replaced and stamped with their current
# last-updated time from FACTS. Items that are no longer open drop out.
merge_digest() {
  md_open=$(open_items "$3")
  { printf '%s\n' "$1"; printf '%s\n' "$2" | tr -d '\r' | awk -v open="$md_open" '
      BEGIN { n = split(open, o, "\n"); for (i = 1; i <= n; i++) { split(o[i], f, "\t"); if (f[1] != "") { kind[f[1]] = f[2]; at[f[1]] = f[3] } } }
      {
        n = split($0, p, / *\| */)
        num = p[1]; gsub(/[^0-9]/, "", num)
        if (num == "" || !(num in kind) || n < 5) next
        summary = p[5]; for (i = 6; i <= n; i++) summary = summary " | " p[i]
        for (i = 2; i <= 4; i++) gsub(/\t/, " ", p[i]); gsub(/\t/, " ", summary)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", num, kind[num], at[num], tolower(p[2]), p[3], p[4], summary
      }'; } | awk -F'\t' -v open="$md_open" '
    BEGIN { n = split(open, o, "\n"); for (i = 1; i <= n; i++) { split(o[i], f, "\t"); if (f[1] != "") isopen[f[2] ":" f[1]] = 1 } }
    NF >= 7 && ($2 ":" $1) in isopen { last[$2 ":" $1] = $0; if (!(($2 ":" $1) in order)) { order[$2 ":" $1] = ++c; keys[c] = $2 ":" $1 } }
    END { for (i = 1; i <= c; i++) print last[keys[i]] }'
}

# batch_paths PATHS SIZE
# PATHS is one file path per line. Print them SIZE to a line, space
# separated: one line per reader.
batch_paths() {
  printf '%s\n' "$1" | awk -v size="${2:-8}" '
    NF == 0 { next }
    { line = (c % size == 0) ? $0 : line " " $0; c++; if (c % size == 0) { print line; line = "" } }
    END { if (line != "") print line }'
}

# digest_brief_lines FACTS DIGEST [LIMIT]
# For the session brief: one line per open item where someone must act
# next, from the saved digest, so the first reply already knows who has the
# ball. Items waiting on the owner come first, then blocked, then the rest
# of what is in progress. "#30 Choose the logo: ball agent; next ...".
# A summary written before the item last changed is marked "(changed since)".
digest_brief_lines() {
  open_items "$1" | awk -F'\t' -v digest="$2" -v facts="$1" -v limit="${3:-8}" '
    function state_of(labels,   n, i, parts, l) {
      n = split(labels, parts, ",")
      for (i = 1; i <= n; i++) { l = tolower(parts[i]); gsub(/^[ \t]+|[ \t]+$/, "", l); if (l ~ /^state:/) { sub(/^state:[ \t]*/, "", l); gsub(/[ \t]+/, "-", l); return l } }
      return "none"
    }
    BEGIN {
      n = split(digest, d, "\n")
      for (i = 1; i <= n; i++) { split(d[i], f, "\t"); if (f[1] != "") { k = f[2] ":" f[1]; at[k] = f[3]; ball[k] = f[4]; nxt[k] = f[5]; blk[k] = f[6] } }
      n = split(facts, fl, "\n")
      for (i = 1; i <= n; i++) { split(fl[i], f, "\t"); if (f[1] == "issue") st["issue:" f[2]] = state_of(f[4]) }
    }
    {
      k = $2 ":" $1
      if (!(k in ball)) next
      s = (k in st) ? st[k] : "pr"
      rank = (s == "waiting-on-owner") ? 1 : (s == "blocked") ? 2 : (s == "in-progress") ? 3 : ($2 == "pr") ? 4 : 9
      if (rank == 9) next
      line = "#" $1 " " $4 ": ball " ball[k] "; next " nxt[k]
      if (blk[k] != "" && blk[k] != "-") line = line "; blocked by " blk[k]
      if (at[k] != $3) line = line " (changed since)"
      out[rank, ++cnt[rank]] = line
    }
    END {
      shown = 0
      for (r = 1; r <= 4; r++) for (i = 1; i <= cnt[r]; i++) { if (shown < limit) { print out[r, i]; shown++ } else more++ }
      if (more > 0) printf "(and %d more in the digest)\n", more
    }'
}

# digest_goals FACTS DIGEST
# Goals the digest adds to a proposal, because labels alone miss them:
#   set-ready N TITLE   the issue is labeled waiting on owner, but the
#                       digest says the ball is back with the agent
#   mark-waiting N TITLE   the issue is ready or in progress, but the
#                       digest says a question to the owner is open
# Only current summaries count; a stale one proposes nothing.
digest_goals() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v digest="$2" '
    function state_of(labels,   n, i, parts, l) {
      n = split(labels, parts, ",")
      for (i = 1; i <= n; i++) { l = tolower(parts[i]); gsub(/^[ \t]+|[ \t]+$/, "", l); if (l ~ /^state:/) { sub(/^state:[ \t]*/, "", l); gsub(/[ \t]+/, "-", l); return l } }
      return "none"
    }
    BEGIN { n = split(digest, d, "\n"); for (i = 1; i <= n; i++) { split(d[i], f, "\t"); if (f[2] == "issue") { at[f[1]] = f[3]; ball[f[1]] = f[4] } } }
    $1 == "issue" && ($2 in ball) && at[$2] == $5 {
      s = state_of($4)
      if (s == "waiting-on-owner" && ball[$2] == "agent") printf "set-ready %s\t%s (the owner answered)\n", $2, $3
      else if ((s == "ready" || s == "in-progress") && ball[$2] == "owner") printf "mark-waiting %s\t%s (a question to the owner is open)\n", $2, $3
    }'
}
