#!/bin/sh
# Keeps this machine's connection to SipNShip open while a session runs, so
# a press on the dashboard starts the drive here within moments
# (specs/030-plugin-wake). The connection itself is console/wake.js.
#
# At a session's start (each look of the app's timed drive is one too): marks
# the session and starts the connection for this project's repository when it
# is not running, and prints the one line a refused token owes, once. At a
# turn's end: marks the session, and starts the connection again, out of the
# way, only when none has been heard from in two minutes (it ends by itself
# once no session has been seen for a while). Nothing else runs.
#
# Only when this machine holds a repository token (npx sipnship connect
# --repo) and has node. Never prints a token; always exits 0.
sn_home="${SIPNSHIP_HOME:-$HOME/.sipnship}"
[ -f "$sn_home/tokens.json" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
here=$(dirname "$0")
. "$here/lib.sh"

input=$(cat)
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] || exit 0
mkdir -p "$sn_home/wake" 2>/dev/null || exit 0
cli="$here/../../console/cli.js"

if [ "$(json_field "$input" hook_event_name)" = Stop ]; then
  touch "$sn_home/wake/seen" 2>/dev/null
  heard=$(find "$sn_home/wake/alive" -mmin -2 2>/dev/null)
  [ -n "$heard" ] && exit 0
  ( node "$cli" wake start --root "$root" ) </dev/null >/dev/null 2>&1 &
  exit 0
fi

said=$(node "$cli" wake start --root "$root" </dev/null 2>/dev/null | head -n 1)
[ -n "$said" ] && printf '%s\n' "$said"
exit 0
