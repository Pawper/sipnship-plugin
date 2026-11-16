#!/bin/sh
# A comment from a file is its contents, never its name. `gh api` with a lowercase -f field
# sends the literal string "@file"; only the uppercase -F field reads the file, and a
# drive tick once left a comment whose whole text was a file name. Sourced by
# comment.sh and by the readers of the drive issue. Pure.

# unoffered_permission TEXT
# For a comment that is an `Instructions:` step (the builder's to do outside
# the app), the name of a token permission it asks for that a fine-grained
# GitHub token does not have ("Checks"), or nothing. A step that cannot be
# done sat in Needs you for a day once, and the drive repeated it every tick.
unoffered_permission() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    NR == 1 && $0 !~ /^[ \t*_]*Instructions:/ { exit }
    { l = tolower($0) }
    l ~ /(^|[^a-z])checks"?:? *(\(|:)? *(read|write)/ || l ~ /(^|[^a-z])"?checks"? +permission/ { print "Checks"; exit }'
}

# comment_refusal FILE
# Nothing when FILE can be posted; else why not, in plain words: the file is
# missing, empty, or its whole text is a path (a body that starts with "@" and
# has no space is a file name that never got read).
comment_refusal() {
  [ -f "$1" ] || { echo "There is no file $1 to post."; return 0; }
  cr_body=$(tr -d '\r' < "$1")
  [ -n "$(printf '%s' "$cr_body" | tr -d ' \t\n')" ] || { echo "The file $1 is empty; nothing is posted."; return 0; }
  cr_perm=$(unoffered_permission "$cr_body")
  [ -z "$cr_perm" ] || { echo "The step asks for a \"$cr_perm\" permission, which GitHub does not offer on a fine-grained token, so the builder could not do it. Name only permissions that exist there (Actions, Administration, Commit statuses, Contents, Issues, Pull requests, Workflows); the drive reads checks from the Actions runs and commit statuses and needs no Checks permission."; return 0; }
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
