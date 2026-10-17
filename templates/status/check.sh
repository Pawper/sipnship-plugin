#!/bin/sh
# Fail when STATUS.md does not match what the stubs would produce.
# Run from the project root or from CI: sh status/check.sh
here=$(dirname "$0")
root="$here/.."
. "$here/lib.sh"

if [ ! -f "$root/STATUS.md" ]; then
  echo "STATUS.md is missing: run sh status/build.sh and commit the result." >&2
  exit 1
fi
expected=$(render_status "$here/stubs" "$here/services.txt")
actual=$(tr -d '\r' < "$root/STATUS.md")
if [ "$expected" = "$actual" ]; then
  echo "STATUS.md is current."
  exit 0
fi
echo "STATUS.md is stale: run sh status/build.sh and commit the result." >&2
exit 1
