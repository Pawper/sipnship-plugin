#!/bin/sh
# Pure helpers for the model a timed drive round runs on (specs/023-drive-on-work).
# A round mostly runs fixed scripts and writes a report, so it takes the model
# the drive's settings name as roundModel, written as one `model:` line in the
# frontmatter of the scheduled task's own file. Nothing here runs git or gh.

# round_model_set TEXT MODEL
# TEXT is the task file's text (frontmatter between two `---` lines first).
# Prints it with its `model:` line set to MODEL: an existing line is replaced,
# a missing one is added as the frontmatter's last line, and a file with no
# frontmatter gets one. MODEL empty prints TEXT unchanged.
round_model_set() {
  if [ -z "$2" ]; then printf '%s\n' "$1"; return 0; fi
  printf '%s\n' "$1" | tr -d '\r' | awk -v m="$2" '
    NR == 1 && $0 != "---" { print "---"; print "model: " m; print "---"; print; next }
    NR == 1 { infm = 1; print; next }
    infm && /^model:/ { print "model: " m; done = 1; next }
    infm && $0 == "---" { if (!done) print "model: " m; done = 1; infm = 0; print; next }
    { print }'
}

# round_model_read TEXT
# The model named in the frontmatter's `model:` line, empty when there is none.
round_model_read() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    NR == 1 { if ($0 == "---") infm = 1; next }
    infm && $0 == "---" { exit }
    infm && /^model:/ { sub(/^model:[ \t]*/, ""); print; exit }'
}

# round_model_check TEXT MODEL
# "ok" when the task names MODEL, else "wrong: <what it names or nothing>".
round_model_check() {
  _rm_have=$(round_model_read "$1")
  if [ "$_rm_have" = "$2" ]; then echo ok; else echo "wrong: ${_rm_have:-no model named}"; fi
}
