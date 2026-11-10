#!/bin/sh
# Sends this machine's session sample to SipNShip, so the dashboard's Work
# tab knows which agent works which issue. At a session's start, beside
# session-brief.sh, at once (the brief reads the whole project and can run
# past its hook's time). Also when an agent is dispatched (SubagentStart, and
# the Agent or Task call after it), when one stops (SubagentStop) and when a
# turn ends (Stop), so an agent a session starts later is on its card, and
# off it, within seconds, not only when the next session starts. And after
# any tool call (the hook's first argument is "tool"), at most once every
# EVERY seconds per repository, so a working agent's line reaches the
# dashboard during a long turn.
#
# The spacing, per repository, in brief-send/sample-at-OWNER-NAME: the time
# the next send reads the logs, or the last one did. An agent starting or
# stopping is never dropped: it is covered when a send is already set to
# read after it, else one is set, at least GAP seconds after the last (the
# service drops a send from the same machine five seconds behind the last).
# An agent's start reads DELAY seconds on, once its log is written. A turn's
# end, and a tool call, send only when some session's last line or state
# differs from the last send's (brief-send/sample-sum-OWNER-NAME, its hash);
# a turn's end sends anyway when nothing went for a minute. Those sends run
# in the background, print nothing and never hold up the event. Only when
# this machine holds a token for the repository (npx sipnship connect --repo).
# One request, a few seconds at most; always exits 0; never prints a token.
sn_home="${SIPNSHIP_HOME:-$HOME/.sipnship}"
every=${SIPNSHIP_SAMPLE_EVERY:-20}

# After a tool call, the mark is read first and no program is started when
# it says no: the project's folder names its repository's mark through
# brief-send/root-FOLDER, which the first call writes. Shell builtins only,
# where the shell has them (bash's), since a tool call waits for this.
if [ "${1:-}" = tool ]; then
  [ -f "$sn_home/tokens.json" ] || exit 0
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    if [ -n "${BASH_VERSION:-}" ]; then eval 'sn_key=${CLAUDE_PROJECT_DIR//[^A-Za-z0-9]/-}'; else sn_key=$(printf '%s' "$CLAUDE_PROJECT_DIR" | tr -c 'A-Za-z0-9' '-'); fi
    sn_mark= sn_last=
    { read -r sn_mark < "$sn_home/brief-send/root-$sn_key"; } 2>/dev/null
    [ -n "$sn_mark" ] && { read -r sn_last < "$sn_home/brief-send/sample-at-$sn_mark"; } 2>/dev/null
    case $sn_last in
      ''|*[!0-9]*) ;;
      *) sn_now=${SIPNSHIP_SAMPLE_NOW:-${EPOCHSECONDS:-$(date +%s 2>/dev/null)}}
         [ -n "$sn_now" ] && [ $((sn_now - sn_last)) -lt "$every" ] && exit 0 ;;
    esac
  fi
fi

here=$(dirname "$0")
. "$here/lib.sh"

input=$(cat)
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] && cd "$root" 2>/dev/null || exit 0

[ -f "$sn_home/tokens.json" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

sn_repo=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
[ -n "$sn_repo" ] || exit 0
mkdir -p "$sn_home/brief-send" 2>/dev/null || exit 0
sn_name=$(printf '%s' "$sn_repo" | tr -c 'A-Za-z0-9._\n-' '-')
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && printf '%s\n' "$sn_name" > "$sn_home/brief-send/root-$(printf '%s' "$CLAUDE_PROJECT_DIR" | tr -c 'A-Za-z0-9' '-')" 2>/dev/null

event=$(json_field "$input" hook_event_name)
# SIPNSHIP_SAMPLE_NOW is a clock handed in by a test, so the spacing can be
# checked without the machine's speed or load deciding the answer.
now=${SIPNSHIP_SAMPLE_NOW:-$(date +%s 2>/dev/null)} || exit 0
[ -n "$now" ] || exit 0
delay=${SIPNSHIP_SAMPLE_DELAY:-3}
gap=${SIPNSHIP_SAMPLE_GAP:-6}

# An agent that stopped is noted by its id, so the sample says it ended
# rather than leaving it working until it has been quiet a quarter hour.
if [ "$event" = SubagentStop ]; then
  agent=$(json_field "$input" agent_id | tr -dc 'A-Za-z0-9_-')
  if [ -n "$agent" ]; then
    ended="$sn_home/brief-send/agents-ended.tsv"
    { tail -n 199 "$ended" 2>/dev/null; printf '%s\t%s\n' "$agent" "$now"; } > "$ended.next" 2>/dev/null && cat "$ended.next" > "$ended" 2>/dev/null
  fi
fi

mark="$sn_home/brief-send/sample-at-$sn_name"
last=$(tr -dc '0-9' 2>/dev/null < "$mark")
at=
changed=
if [ "${1:-}" = tool ]; then
  # The dispatching call has its own hook, below.
  case $(json_field "$input" tool_name) in Agent|Task) exit 0 ;; esac
  [ -n "$last" ] && [ $((now - last)) -lt "$every" ] && exit 0
  at=$now changed=--if-changed
else
  case "$event" in
    ""|SessionStart)
      # At once, and its line printed, unless a send is too close to it.
      [ -n "$last" ] && [ $((now - last)) -lt "$gap" ] && at=$((last + gap)) ;;
    SubagentStart|SubagentStop|PostToolUse)
      [ -n "$last" ] && [ "$last" -gt "$now" ] && exit 0
      at=$now
      [ "$event" = SubagentStop ] || at=$((now + delay))
      [ -n "$last" ] && [ $((last + gap)) -gt "$at" ] && at=$((last + gap)) ;;
    *)
      at=$now
      if [ -n "$last" ] && [ $((now - last)) -lt 60 ]; then
        [ "$last" -gt "$now" ] && exit 0
        changed=--if-changed
        [ $((last + gap)) -gt "$at" ] && at=$((last + gap))
      fi ;;
  esac
fi
printf '%s\n' "${at:-$now}" > "$mark" 2>/dev/null

if command -v timeout >/dev/null 2>&1; then bound="timeout 8"; else bound=""; fi
session=$(json_field "$input" session_id)
send() {
  $bound node "$here/../../console/brief-send.js" --sample $changed --digest-file "$sn_home/brief-send/sample-sum-$sn_name" --session "$session" --repo "$sn_repo" --machine-file "$sn_home/runner-watch/machine.tsv" </dev/null 2>/dev/null
}
if [ -z "$at" ]; then
  sn_said=$(send | head -n 1)
  [ -n "$sn_said" ] && printf '%s\n' "$sn_said"
  exit 0
fi
wait_s=$((at - now))
( [ "$wait_s" -gt 0 ] && sleep "$wait_s"; send >/dev/null ) </dev/null >/dev/null 2>&1 &
exit 0
