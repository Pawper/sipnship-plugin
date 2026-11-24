# Sourced by session-brief-slow.sh, in the background: how many lines
# scripts/ci/template-exceptions.txt holds (#2470), and the oldest, read
# from the commit that added the line, by git blame on the file (local
# only, no network). Only this repository, the plugin's own home, has the
# file at all.
if has leftover && [ -f scripts/ci/template-exceptions.txt ] && [ "$have_git" = yes ]; then
  ex_n=$(grep -vE '^[[:space:]]*(#|$)' scripts/ci/template-exceptions.txt 2>/dev/null | grep -c .)
  if [ "$ex_n" -gt 0 ]; then
    # Each line's own commit date (blame, not the file's), earliest first;
    # ISO dates sort correctly as plain text.
    ex_oldest=$(git blame --date=short -- scripts/ci/template-exceptions.txt 2>/dev/null \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | head -n 1)
    ex_s=""; [ "$ex_n" = 1 ] || ex_s=s
    ex_line="This project has $ex_n setup exception$ex_s from the plugin's shipped copies (scripts/ci/template-exceptions.txt)"
    [ -z "$ex_oldest" ] || ex_line="$ex_line; the oldest since $ex_oldest"
    add "$ex_line."
  fi
fi
