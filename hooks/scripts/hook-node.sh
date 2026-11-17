#!/bin/sh
# Starts the Node program that runs a hook's checks (specs/027-hooks-in-node):
#
#   sh hook-node.sh EVENT [ARGS...]      for example: sh hook-node.sh pre-bash
#
# Standard input, output and the exit status are the program's own. Where
# Node is missing the checks are skipped with no output and no error, the
# same as for a Node below the floor (run.js ends at once there); CI still
# enforces every rule on the pull request, and the session brief says so.
command -v node >/dev/null 2>&1 || exit 0
exec node "$(dirname "$0")/../node/run.js" "$@"
