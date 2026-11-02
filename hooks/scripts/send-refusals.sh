#!/bin/sh
# Run by watch-resolution.sh at the end of an agent's turn, after it has
# settled every open refusal: tells SipNShip what settled since the last
# send (console/refusal-report.js; spec 013), only when this machine holds
# a token for the repository and HOOK_LOG is not 0. One request, three
# seconds at most, so a session never waits on it. A turn with nothing new
# sends nothing and starts nothing. Prints at most one plain line, and always
# exits 0. Nothing here prints a token or any text of a command.
here=$(dirname "$0")
. "$here/lib.sh"

[ "${HOOK_LOG:-1}" != 0 ] || exit 0
input=$(cat)
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] && cd "$root" 2>/dev/null || exit 0

# Nothing settled yet, or everything already sent: no process, no request.
[ -s .scratch/hooks-resolved.log ] || exit 0
if [ -s .scratch/hooks/sent ] && [ "$(tail -n 1 .scratch/hooks-resolved.log | cut -f2)" = "$(head -n 1 .scratch/hooks/sent | tr -d '\r')" ]; then exit 0; fi

sn_home="${SIPNSHIP_HOME:-$HOME/.sipnship}"
[ -f "$sn_home/tokens.json" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
sn_repo=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
[ -n "$sn_repo" ] || exit 0

if command -v timeout >/dev/null 2>&1; then bound="timeout 4"; else bound=""; fi
sn_said=$($bound node "$here/../../console/refusal-report.js" --repo "$sn_repo" --session "$(json_field "$input" session_id)" </dev/null 2>/dev/null | head -n 1)
[ -n "$sn_said" ] && printf '%s\n' "$sn_said"
exit 0
