#!/bin/sh
# Build STATUS.md from the stubs. Run from the project root: sh status/build.sh
set -e
here=$(dirname "$0")
root="$here/.."
. "$here/lib.sh"

render_status "$here/stubs" "$here/services.txt" > "$root/STATUS.md.new"
mv "$root/STATUS.md.new" "$root/STATUS.md"
echo "Wrote STATUS.md"
