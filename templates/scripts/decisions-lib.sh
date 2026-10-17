#!/bin/sh
# Pure helpers for decisions kept one per file. Text in, text out.
#
# A product brief whose decisions table every pull request appends a row
# to is a shared page: any two pull requests open together conflict on its
# last line, and agents race for the next D number. One project reached
# D124 written before D123. One file per decision, numbered by
# next-number.sh across main and every open pull request, never collides.

# decision_rows TEXT
# The decision rows of a Markdown table in TEXT ("| D123 | 2026-10-13 |
# The text |"), as "number<TAB>date<TAB>text", one per line, in file order.
# A row with no date cell gives an empty date.
decision_rows() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^\|[ \t]*D[0-9]+[ \t]*\|/ {
      n = split($0, c, "|")
      num = c[2]; gsub(/[^0-9]/, "", num)
      if (n >= 5) { d = c[3]; t = c[4]; for (i = 5; i < n; i++) t = t "|" c[i] }
      else { d = ""; t = c[3] }
      gsub(/^[ \t]+|[ \t]+$/, "", d); gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { if (t == "") t = d; else if (d != "") t = d " | " t; d = "" }
      printf "%s\t%s\t%s\n", num, d, t
    }'
}

# decision_slug TEXT
# A short file-name slug from the first words of TEXT: lower case, letters
# and digits, words joined by "-", at most six words.
decision_slug() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9][^a-z0-9]*/ /g' | awk '{ s = ""; for (i = 1; i <= NF && i <= 6; i++) s = s (s == "" ? "" : "-") $i; print (s == "" ? "decision" : s) }'
}

# decision_file NUMBER DATE TEXT
# The content of one decision's file.
decision_file() {
  printf '# D%s\n\nDate: %s\n\n%s\n' "$1" "${2:-unknown}" "$3"
}

# decision_name NUMBER SLUG
# The file name: four digits, so the files sort and next-number reads them.
decision_name() {
  printf '%04d-%s.md\n' "$1" "$2"
}

# decision_table FILES
# FILES is each decision file's content, separated by a line holding only
# "@@@". Print the Markdown table, in number order.
decision_table() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    function flush() { if (num != "") { body = text; gsub(/[ \t]*\n[ \t]*/, " ", body); sub(/^ +/, "", body); sub(/ +$/, "", body); rows[num + 0] = "| D" num " | " date " | " body " |"; if (num + 0 > max) max = num + 0 } num = ""; date = ""; text = ""; seen_date = 0 }
    $0 == "@@@" { flush(); next }
    /^# D[0-9]+/ { flush(); num = $0; sub(/^# D/, "", num); sub(/[^0-9].*/, "", num); next }
    /^Date:/ { date = $0; sub(/^Date:[ \t]*/, "", date); seen_date = 1; next }
    { if (num != "" && seen_date && $0 != "") text = text (text == "" ? "" : "\n") $0 }
    END {
      flush()
      print "| Decision | Date | What was decided |"
      print "|---|---|---|"
      for (i = 0; i <= max; i++) if (i in rows) print rows[i]
    }'
}
