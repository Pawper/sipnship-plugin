#!/bin/sh
# Pure helper for planning a round (specs/023-drive-on-work): text in, text out.
# bundle-lib.sh's plan_units keeps what it names apart from other work.

# reads_held TEXT FILES
# "yes" when the change an issue asks for will be held for the builder's read
# when it opens, and so must never share a pull request with work that needs no
# read (specs/023-drive-on-work): a change under the specs or the mocks folders
# alone, or an issue that says it is a draft for the builder's read and touches
# no code. FILES are the guessed files, comma separated. A body that merely
# talks about drafts but names code files is code work.
reads_held() {
  rh_files=$(printf '%s\n' "$2" | tr ',' '\n' | sed '/^$/d')
  rh_code=no
  rh_any=no
  for rh_f in $rh_files; do
    rh_any=yes
    case "$rh_f" in specs/*|design/mocks/*|docs/*) ;; *) rh_code=yes ;; esac
  done
  [ "$rh_code" = no ] || { echo no; return 0; }
  if [ "$rh_any" = yes ] && ! printf '%s\n' "$rh_files" | grep -qvE '^(specs|design/mocks)/'; then echo yes; return 0; fi
  if printf '%s\n' "$1" | tr -d '\r' | grep -qiE "draft[^.]{0,80}(for (the )?(owner|builder|your)('s)? read|to read)|(held|waits?) for (the )?(owner|builder|your)('s)? read|(owner|builder)('s)? (to )?read (it|the draft)"; then echo yes; else echo no; fi
}
