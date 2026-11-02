#!/bin/sh
# SessionStart hook, beside session-brief.sh: sends this machine's session
# sample to SipNShip at once, so the dashboard's Work tab knows which agent
# works which issue even when the brief, which reads the whole project, runs
# past its own hook's time and is stopped before its send. Only when this
# machine holds a token for the repository (npx sipnship connect --repo).
# One request, a few seconds at most; prints at most one plain line and
# always exits 0. Nothing here prints a token.
here=$(dirname "$0")
. "$here/lib.sh"

input=$(cat)
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] && cd "$root" 2>/dev/null || exit 0

sn_home="${SIPNSHIP_HOME:-$HOME/.sipnship}"
[ -f "$sn_home/tokens.json" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
sn_repo=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
[ -n "$sn_repo" ] || exit 0

if command -v timeout >/dev/null 2>&1; then bound="timeout 8"; else bound=""; fi
sn_said=$($bound node "$here/../../console/brief-send.js" --sample --session "$(json_field "$input" session_id)" --repo "$sn_repo" --machine-file "$sn_home/runner-watch/machine.tsv" </dev/null 2>/dev/null | head -n 1)
[ -n "$sn_said" ] && printf '%s\n' "$sn_said"
exit 0
