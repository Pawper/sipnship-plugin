#!/bin/sh
# SessionStart hook, beside session-brief.sh: sends this machine's session
# sample to SipNShip at once, so the dashboard's Work tab knows which agent
# works which issue even when the brief, which reads the whole project, runs
# past its own hook's time and is stopped before its send. Also on
# SubagentStart, SubagentStop and Stop, so an agent a session starts later is
# on its card within a minute, not only when the next session starts: those
# send at most once a minute and print nothing. Only when this machine holds
# a token for the repository (npx sipnship connect --repo). One request, a
# few seconds at most; prints at most one plain line and always exits 0.
# Nothing here prints a token.
here=$(dirname "$0")
. "$here/lib.sh"

input=$(cat)
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] && cd "$root" 2>/dev/null || exit 0

sn_home="${SIPNSHIP_HOME:-$HOME/.sipnship}"
[ -f "$sn_home/tokens.json" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# Any event but a session's start sends at most once a minute, and quietly.
event=$(json_field "$input" hook_event_name)
mark="$sn_home/brief-send/sample-at"
now=$(date +%s 2>/dev/null || echo 0)
quiet=
if [ -n "$event" ] && [ "$event" != "SessionStart" ]; then
  last=$(tr -dc '0-9' < "$mark" 2>/dev/null)
  [ -n "$last" ] && [ $((now - last)) -lt 60 ] && exit 0
  quiet=1
fi
mkdir -p "$sn_home/brief-send" 2>/dev/null && printf '%s\n' "$now" > "$mark" 2>/dev/null

sn_repo=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
[ -n "$sn_repo" ] || exit 0

if command -v timeout >/dev/null 2>&1; then bound="timeout 8"; else bound=""; fi
sn_said=$($bound node "$here/../../console/brief-send.js" --sample --session "$(json_field "$input" session_id)" --repo "$sn_repo" --machine-file "$sn_home/runner-watch/machine.tsv" </dev/null 2>/dev/null | head -n 1)
[ -z "$quiet" ] && [ -n "$sn_said" ] && printf '%s\n' "$sn_said"
exit 0
