#!/bin/sh
# Pure helpers for numbers that parallel work collides on: migration
# numbers, task numbers, setup steps. Text in, text out; no git, no gh.
#
# The rule they serve: a running number in a shared place is a merge
# conflict waiting to happen. Name work by its issue number where you can;
# where a sequence is required (migrations run in order), reserve the next
# free number across main and every open pull request, and check at merge
# time that no number was taken twice.

# numbering_glob CONFIG KIND
# CONFIG is the text of .claude/numbering.txt: lines "KIND GLOB", for
# example "migration supabase/migrations/*.sql". Print the glob for KIND,
# or nothing.
numbering_glob() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v k="$2" '$1 == k && NF >= 2 { print $2; exit }'
}

# numbers_in PATHS GLOB
# PATHS is one path per line. Print the leading number of each file name
# that matches GLOB, one per line, as written (zero padding kept).
numbers_in() {
  set -f
  ni_out=$(printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | while IFS= read -r ni_p; do
    [ -n "$ni_p" ] || continue
    case "$ni_p" in $2) ;; *) continue ;; esac
    ni_base=${ni_p##*/}
    ni_num=$(printf '%s' "$ni_base" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
    if [ -n "$ni_num" ]; then printf '%s\n' "$ni_num"; fi
  done)
  set +f
  [ -n "$ni_out" ] && printf '%s\n' "$ni_out"
  return 0
}

# next_free_number NUMBERS
# NUMBERS is one number per line, any padding. Print the next number
# after the largest, padded to the widest width seen (at least four), so
# 0021 and 0022 give 0023 and an empty list gives 0001.
next_free_number() {
  printf '%s\n' "$1" | awk '
    /^[0-9]+$/ { v = $0 + 0; if (v > max) max = v; if (length($0) > w) w = length($0) }
    END { if (w < 4) w = 4; printf "%0" w "d\n", max + 1 }'
}

# duplicate_numbers PATHS GLOB
# Print each number that two or more files matching GLOB share, with the
# files: "0022<TAB>a.sql b.sql". A batch that merged two pull requests
# which each took 0022 shows here before it reaches main.
duplicate_numbers() {
  set -f
  dn_rows=$(printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | while IFS= read -r dn_p; do
    [ -n "$dn_p" ] || continue
    case "$dn_p" in $2) ;; *) continue ;; esac
    dn_num=$(printf '%s' "${dn_p##*/}" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
    # Compare by value, so 22 and 0022 are the same number.
    if [ -n "$dn_num" ]; then printf '%s\t%s\n' "$(printf '%s' "$dn_num" | sed 's/^0*//; s/^$/0/')" "${dn_p##*/}"; fi
  done)
  set +f
  printf '%s\n' "$dn_rows" | awk -F'\t' '
    NF >= 2 { n[$1]++; files[$1] = (files[$1] == "") ? $2 : files[$1] " " $2 }
    END { for (k in n) if (n[k] > 1) printf "%04d\t%s\n", k, files[k] }' | sort
}

# running_task_lines ADDED_LINES
# ADDED_LINES are lines a change adds to a task file. Print the ones that
# start a task with a running number ("## 14.", "- [ ] 7:", "T12)",
# "7p.") and do not name an issue (#123). Task numbers collide when two
# pull requests each take the next one; an issue number never does.
running_task_lines() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    {
      l = $0
      if (l ~ /#[0-9]+/) next
      s = l
      sub(/^[ \t]*(#+[ \t]*|[-*+][ \t]+(\[[ xX]\][ \t]+)?)?/, "", s)
      if (s ~ /^([Tt]ask[ \t]*|[Tt])?[0-9]+[a-z]?[.:)]([ \t]|$)/) print l
    }'
}

# pending_migrations MANUAL ADDED_PATHS GLOB
# MANUAL is the text of the project's setup manual. ADDED_PATHS are the
# files a pull request adds. Print each added migration (matching GLOB)
# that the manual does not mark as done: no line mentions it, or the line
# that does still says "Not yet run". A pull request that needs a
# migration run may merge only after the run, when its line says Done.
pending_migrations() {
  set -f
  pm_added=$(printf '%s\n' "$2" | tr -d '\r' | tr '\\' '/' | while IFS= read -r pm_p; do
    [ -n "$pm_p" ] || continue
    case "$pm_p" in $3) printf '%s\n' "${pm_p##*/}" ;; esac
  done)
  set +f
  [ -n "$pm_added" ] || return 0
  printf '%s\n' "$1" | tr -d '\r' | awk -v added="$pm_added" '
    BEGIN { n = split(added, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") { want[a[i]] = 1; order[++c] = a[i] } }
    {
      for (f in want) {
        # The manual may name the file without its extension; both count.
        b = f; sub(/\.[A-Za-z0-9]+$/, "", b)
        if (index($0, f) == 0 && (b == "" || index($0, b) == 0)) continue
        seen[f] = 1
        if ($0 ~ /[Nn]ot yet run/ && $0 !~ /(^|[^A-Za-z])[Dd]one[ \t]+[0-9]/) pending[f] = 1
      }
    }
    END { for (i = 1; i <= c; i++) { f = order[i]; if (!(f in seen)) print f "\tnot in the manual"; else if (f in pending) print f "\tnot yet run" } }'
}

# An ID kind lives inside one file rather than in file names: decisions
# D1, D2, ... in a product brief. Its line in .claude/numbering.txt has
# three fields, "KIND FILE PREFIX", for example
#   decision docs/product-brief.md D

# numbering_prefix CONFIG KIND
# The ID prefix for KIND, or nothing for a file-name kind.
numbering_prefix() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v k="$2" '$1 == k && NF >= 3 { print $3; exit }'
}

# id_definitions TEXT PREFIX
# The numbers of the IDs TEXT defines, one per line, in order. A line
# defines an ID when the ID comes first, after any table bar, heading
# mark, list mark, quote mark or bold: "| D55 | ...", "## D55 ...",
# "- **D55** ...". A mention in prose, "(D34)", is a reference, not a
# definition.
id_definitions() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v pre="$2" '
    {
      l = $0
      sub(/^[ \t|#>*+-]*/, "", l); sub(/^\*\*/, "", l)
      if (index(l, pre) != 1) next
      r = substr(l, length(pre) + 1)
      if (match(r, /^[0-9]+/) && substr(r, RLENGTH + 1, 1) !~ /[0-9A-Za-z_]/) print substr(r, 1, RLENGTH) + 0
    }'
}

# duplicate_ids TEXT PREFIX
# The IDs TEXT defines more than once, one per line: "D55".
duplicate_ids() {
  id_definitions "$1" "$2" | awk -v pre="$2" '{ n[$0]++ } END { for (k in n) if (n[k] > 1) print pre k }' | sort -t"$2" -k2 -n
}

# next_free_id NUMBERS PREFIX
# The next ID after the largest number: "D57". An empty list gives "D1".
next_free_id() {
  printf '%s\n' "$1" | awk -v pre="$2" '/^[0-9]+$/ { if ($0 + 0 > max) max = $0 + 0 } END { print pre (max + 1) }'
}

# migration_glob_guess FILES
# FILES is one tracked path per line. Print the migration glob the files
# fit, the first of supabase/migrations/*.sql, migrations/*.sql,
# db/migrations/*.sql, database/migrations/*.sql with a file in it, or
# nothing. A Supabase project shipped with "migrations/*.sql", next-number
# answered 0001 to every agent all day, and the gate refused a real one.
migration_glob_guess() {
  printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | awk '
    /^supabase\/migrations\/[^\/]+\.sql$/ { s = 1 }
    /^migrations\/[^\/]+\.sql$/ { m = 1 }
    /^db\/migrations\/[^\/]+\.sql$/ { d = 1 }
    /^database\/migrations\/[^\/]+\.sql$/ { b = 1 }
    END {
      if (s) print "supabase/migrations/*.sql"
      else if (m) print "migrations/*.sql"
      else if (d) print "db/migrations/*.sql"
      else if (b) print "database/migrations/*.sql"
    }'
}
