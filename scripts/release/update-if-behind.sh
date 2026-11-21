#!/bin/sh
# First thing in a timed round and in a wake: bring the installed copy up to
# the newest published version when it is behind, by script, with no model
# deciding what kind of session this is. Prints one line and exits 0
# whatever happens, so a round is never stopped by it:
#   plugin: moved from 0.43.50 to 0.43.54
#   plugin: current at 0.43.54
#   plugin: could not update from 0.43.50 to 0.43.54 (why)
#   plugin: not checked (why)
# The new scripts apply from the next start; this run finishes on the ones it began with.
#
#   sh plugin/scripts/release/update-if-behind.sh
#
# SIPNSHIP_PUBLISHED names the published version instead of asking GitHub
# (the suite's stand-in); UPDATE_INSTALLED names another update script.
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../.." && pwd)
name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$plugin/.claude-plugin/plugin.json" | head -n 1)
market=${SIPNSHIP_MARKETPLACE:-$name}
list=${SIPNSHIP_PLUGIN_LIST:-$HOME/.claude/plugins/installed_plugins.json}
. "$plugin/hooks/scripts/session-brief-versions.sh"
have=$(plugin_copies_read "$list" "$name@$market" | sed -n 's/^user=\([^ ]*\).*/\1/p')
if [ -z "$have" ]; then echo "plugin: not checked (no installed copy is listed in $list)"; exit 0; fi
pub=${SIPNSHIP_PUBLISHED:-}
if [ -z "$pub" ]; then
  pub=$(gh api "repos/Pawper/sipnship-plugin/tags?per_page=30" --jq '.[].name' 2>/dev/null | tr -d '\r' | sed 's/^plugin-//; s/^v//' | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
fi
if [ -z "$pub" ]; then echo "plugin: not checked (the newest published version could not be read)"; exit 0; fi
if [ "$(ver_lt "$have" "$pub")" != yes ]; then echo "plugin: current at $have"; exit 0; fi
upd=${UPDATE_INSTALLED:-$here/update-installed.sh}
rc=0
if command -v timeout >/dev/null 2>&1; then out=$(timeout -k 5 180 sh "$upd" 2>&1) || rc=$?; else out=$(sh "$upd" 2>&1) || rc=$?; fi
now=$(plugin_copies_read "$list" "$name@$market" | sed -n 's/^user=\([^ ]*\).*/\1/p')
if [ "$rc" = 0 ] && [ -n "$now" ] && [ "$now" != "$have" ]; then echo "plugin: moved from $have to $now"; exit 0; fi
why=$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')
if [ "$rc" = 0 ]; then why="the update ran but the installed copy stayed at $have"; fi
echo "plugin: could not update from $have to $pub (${why:-no reason given})"
exit 0
