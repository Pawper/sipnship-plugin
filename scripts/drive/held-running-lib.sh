#!/bin/sh
# An issue whose only open pull request is held for the owner's read has no
# agent at work, whatever its State label says, so it is not a running unit:
# nothing waits behind it (#2055). Pure helpers, text in and text out.
# PULLS are the plan's pull lines: NUMBER<TAB>HELD(yes|no)<TAB>CLOSES[<TAB>REFS],
# issue numbers comma separated.

# held_only_issues PULLS
# The issues (one a line) that an open pull request held for the owner closes
# or names, and that no open pull request not held closes or names: the held
# read is all there is of their work.
held_only_issues() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    $1 == "" { next }
    {
      n = split($3, a, ","); m = split($4, b, ","); for (i = 1; i <= m; i++) a[++n] = b[i]
      for (i = 1; i <= n; i++) if (a[i] != "") { if ($2 == "yes") held[a[i]] = 1; else live[a[i]] = 1 }
    }
    END { for (k in held) if (!(k in live)) print k }' | sort -n
}

# without_issues LIST OMIT: the numbers of LIST (one a line) that are not in OMIT (one a line).
without_issues() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v omit="$(printf '%s\n' "$2" | tr -d '\r' | tr '\n' ' ')" '
    BEGIN { n = split(omit, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    NF && !($1 in skip)'
}

# held_pull_numbers PULLS: the numbers of the pull requests held for the owner, one a line.
held_pull_numbers() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$2 == "yes" && $1 != "" { print $1 }'
}

# issue_titles_from_facts FACTS: "NUMBER<TAB>TITLE" for every issue fact line
# (facts are "issue<TAB>NUMBER<TAB>TITLE<TAB>..."), one a line. An area hold
# names the issue it waits behind by title, so this must be set on its own
# reachable line, never hidden after a trailing comment (#2066).
issue_titles_from_facts() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 == "issue" { print $2 "\t" $3 }'
}
