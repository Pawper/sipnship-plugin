#!/bin/sh
# A comment from a file is its contents, never its name. `gh api` with a lowercase -f field
# sends the literal string "@file"; only the uppercase -F field reads the file, and a
# drive tick once left a comment whose whole text was a file name. Sourced by
# comment.sh and by the readers of the drive issue. Pure.

# comment_refusal FILE
# Nothing when FILE can be posted; else why not, in plain words: the file is
# missing, empty, or its whole text is a path (a body that starts with "@" and
# has no space is a file name that never got read).
comment_refusal() {
  [ -f "$1" ] || { echo "There is no file $1 to post."; return 0; }
  cr_body=$(tr -d '\r' < "$1")
  [ -n "$(printf '%s' "$cr_body" | tr -d ' \t\n')" ] || { echo "The file $1 is empty; nothing is posted."; return 0; }
  case "$cr_body" in
    @*) case "$cr_body" in *[[:space:]]*) ;; *) echo "The text of $1 is only a file name ($cr_body); it would post the name, not the file. Write the words into the file."; return 0 ;; esac ;;
  esac
}

# without_bare_path_comments LINES
# The drive issue's comment lines (the body is the last tab-separated field)
# without any whose whole body is a bare "@path": one slip is never read as an
# answer, a request or a proposal.
without_bare_path_comments() {
  printf '%s\n' "$1" | awk -F'\t' '$NF ~ /^@[^ \t\\]+$/ { next } { print }'
}
