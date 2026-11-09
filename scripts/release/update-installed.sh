#!/bin/sh
# The last step of a release: bring the installed copy, the one the drive's
# timed task runs, up to the released version.
#
#   sh plugin/scripts/release/update-installed.sh [--check]
#
# Runs `claude plugin marketplace update` and then `claude plugin update`
# for this plugin, and prints which version the installed copy is on. With
# --check it only prints the installed version and changes nothing. Needs
# the claude command on the PATH; when it is missing, says so and exits 1.
# The drive's tick may run this first thing when the marketplace has a
# newer version than the installed one.
plugin=$(cd "$(dirname "$0")/../.." && pwd)
name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$plugin/.claude-plugin/plugin.json" | head -n 1)
market=${SIPNSHIP_MARKETPLACE:-$name}
list=${SIPNSHIP_PLUGIN_LIST:-$HOME/.claude/plugins/installed_plugins.json}
. "$plugin/hooks/scripts/session-brief-versions.sh"
installed() { plugin_copies_read "$list" "$name@$market" | sed -n 's/^user=\([^ ]*\).*/\1/p'; }
if [ "$1" = --check ]; then echo "Installed copy: $(installed)"; exit 0; fi
command -v claude >/dev/null 2>&1 || { echo "claude is not on the PATH; run claude plugin marketplace update $market, then claude plugin update $name@$market" >&2; exit 1; }
before=$(installed)
claude plugin marketplace update "$market" || exit 1
claude plugin update "$name@$market" || exit 1
echo "Installed copy: ${before:-none} -> $(installed). The drive runs this version from its next start."
