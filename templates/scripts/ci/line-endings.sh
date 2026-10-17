#!/bin/sh
# Fail when any tracked text file has CRLF line endings. Mixed endings are
# the cheapest way to make every diff a conflict. .gitattributes should
# already force LF; this check catches the file that slipped past it.
# A file .gitattributes marks eol=crlf on purpose (gradlew.bat, a .cmd
# file Windows must read) is allowed, so a project needs no local patch.
# Usage: sh scripts/ci/line-endings.sh
bad=$(git grep -I -l "$(printf '\r')" -- . ':!*.png' ':!*.jpg' ':!*.gif' ':!*.ico' ':!*.pdf' 2>/dev/null | while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$(git check-attr eol -- "$f" 2>/dev/null)" in *": eol: crlf") continue ;; esac
  printf '%s\n' "$f"
done)
if [ -n "$bad" ]; then
  echo "These files have CRLF line endings; convert them to LF, or mark them eol=crlf in .gitattributes when Windows must read them that way:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
echo "Line endings are LF everywhere."
