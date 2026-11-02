#!/bin/sh
# PostToolUse hook for every tool, and the Stop hook: settles refusals.
# A refusal waits in .scratch/hooks/pending. Each later successful tool
# call in the same session is read against it (resolution_of): followed,
# a possible workaround, or asked the person settle it; after five calls
# that say nothing about it, it "moved on". When the session stops with
# one still open, it is settled as "stopped" (the agent asked in words, or
# left it). Each settled line also holds the seconds and tool calls it took
# and, for a possible workaround, the kind of tool (refusal-time.sh).
# Settling never refuses anything and never prints. At the end of a turn
# (Stop, SubagentStop), once everything is settled, the sender runs (send-
# refusals.sh): it prints at most one line. Always exits 0.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/resolution-lib.sh"
. "$here/refusal-time.sh"

[ "${HOOK_LOG:-1}" != 0 ] || exit 0
input=$(cat)
event=$(json_field "$input" hook_event_name)

settle() {
  dir=${CLAUDE_PROJECT_DIR:-.}
  pending="$dir/.scratch/hooks/pending"
  [ -s "$pending" ] || return 0
  sess=$(json_field "$input" session_id); sess=${sess:-unknown}
  grep -q "	$sess	" "$pending" 2>/dev/null || return 0
  tool=$(json_field "$input" tool_name)
  text=$(json_field "$input" command)
  [ -n "$text" ] || text=$(json_field "$input" file_path)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tab=$(printf '\t')

  : > "$pending.new" 2>/dev/null || return 0
  while IFS="$tab" read -r p_t p_h p_s p_n; do
    [ -n "$p_t" ] || continue
    if [ "$p_s" != "$sess" ]; then printf '%s\t%s\t%s\t%s\n' "$p_t" "$p_h" "$p_s" "$p_n" >> "$pending.new"; continue; fi
    calls=$p_n
    case "$event" in
      Stop|SubagentStop) out=stopped ;;
      *)
        out=$(resolution_of "$p_h" "$tool" "$text")
        if [ -n "$out" ]; then
          calls=$((p_n + 1))
        else
          p_n=$((p_n + 1))
          calls=$p_n
          [ "$p_n" -ge 5 ] && out="moved on"
        fi ;;
    esac
    if [ -n "$out" ]; then
      via=""
      [ "$out" = workaround ] && via=$(refusal_via "$tool")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$p_t" "$p_h" "$p_s" "$out" "$(refusal_seconds "$p_t" "$now")" "$(refusal_calls "$calls")" "$via" >> "$dir/.scratch/hooks-resolved.log"
    else
      printf '%s\t%s\t%s\t%s\n' "$p_t" "$p_h" "$p_s" "$p_n" >> "$pending.new"
    fi
  done < "$pending"
  mv "$pending.new" "$pending" 2>/dev/null || true
  return 0
}
settle

case "$event" in
  Stop|SubagentStop) printf '%s' "$input" | sh "$here/send-refusals.sh" 2>/dev/null ;;
esac
exit 0
