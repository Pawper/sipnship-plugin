#!/bin/sh
# PostToolUse hook for every tool, and the Stop hook: settles refusals.
# A refusal waits in .scratch/hooks/pending. Each later successful tool
# call in the same session is read against it (resolution_of): followed,
# a possible workaround, or asked the person settle it; after five calls
# that say nothing about it, it "moved on". When the session stops with
# one still open, it is settled as "stopped" (the agent asked in words, or
# left it). Never refuses anything and never prints: it always exits 0.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/resolution-lib.sh"

[ "${HOOK_LOG:-1}" != 0 ] || exit 0
dir=${CLAUDE_PROJECT_DIR:-.}
pending="$dir/.scratch/hooks/pending"
[ -s "$pending" ] || exit 0

input=$(cat)
sess=$(json_field "$input" session_id); sess=${sess:-unknown}
grep -q "	$sess	" "$pending" 2>/dev/null || exit 0
event=$(json_field "$input" hook_event_name)
tool=$(json_field "$input" tool_name)
text=$(json_field "$input" command)
[ -n "$text" ] || text=$(json_field "$input" file_path)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tab=$(printf '\t')

: > "$pending.new" 2>/dev/null || exit 0
while IFS="$tab" read -r p_t p_h p_s p_n; do
  [ -n "$p_t" ] || continue
  if [ "$p_s" != "$sess" ]; then printf '%s\t%s\t%s\t%s\n' "$p_t" "$p_h" "$p_s" "$p_n" >> "$pending.new"; continue; fi
  case "$event" in
    Stop|SubagentStop) out=stopped ;;
    *)
      out=$(resolution_of "$p_h" "$tool" "$text")
      if [ -z "$out" ]; then
        p_n=$((p_n + 1))
        [ "$p_n" -ge 5 ] && out="moved on"
      fi ;;
  esac
  if [ -n "$out" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$p_t" "$p_h" "$p_s" "$out" >> "$dir/.scratch/hooks-resolved.log"
  else
    printf '%s\t%s\t%s\t%s\n' "$p_t" "$p_h" "$p_s" "$p_n" >> "$pending.new"
  fi
done < "$pending"
mv "$pending.new" "$pending" 2>/dev/null || true
exit 0
