#!/bin/sh
# Sourced by each refusing hook. When the hook exits 2 (a refusal), one
# line goes to .scratch/hooks.log in the project: the time, the hook's
# name and the session's id, nothing of the command. The refusal also
# waits in .scratch/hooks/pending until a later action settles it (see
# watch-resolution.sh); the same hook refusing again in the same session
# settles the earlier one as "retried". The owner console reads both logs.
# The files stay in the project's ignored scratch folder on this machine;
# HOOK_LOG=0 turns it all off.
# Lines, tab-separated: hooks.log "time hook session id"; pending "id hook
# session count"; hooks-resolved.log "time id hook session outcome".
refusal_log_dir() {
  rl_dir=${CLAUDE_PROJECT_DIR:-.}
  [ -d "$rl_dir/.git" ] || [ -f "$rl_dir/.git" ] || return 1
  printf '%s/.scratch\n' "$rl_dir"
}
refusal_log() {
  [ "${HOOK_LOG:-1}" != 0 ] || return 0
  rl_s=$(refusal_log_dir) || return 0
  mkdir -p "$rl_s/hooks" 2>/dev/null || return 0
  rl_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  rl_hook=$(basename "$0" .sh)
  rl_sess=$(json_field "${input:-}" session_id 2>/dev/null)
  rl_sess=${rl_sess:-unknown}
  # one id per refusal: two in the same second are still two
  rl_id="$rl_now-$$"
  printf '%s\t%s\t%s\t%s\n' "$rl_now" "$rl_hook" "$rl_sess" "$rl_id" >> "$rl_s/hooks.log" 2>/dev/null || return 0
  rl_p="$rl_s/hooks/pending"
  if [ -f "$rl_p" ]; then
    # an earlier refusal by this hook in this session, still open: retried
    awk -F'\t' -v h="$rl_hook" -v s="$rl_sess" '$2 == h && $3 == s' "$rl_p" | while IFS="$(printf '\t')" read -r p_t p_h p_s p_n; do
      printf '%s\t%s\t%s\t%s\tretried\n' "$rl_now" "$p_t" "$p_h" "$p_s" >> "$rl_s/hooks-resolved.log"
    done
    awk -F'\t' -v h="$rl_hook" -v s="$rl_sess" '!($2 == h && $3 == s)' "$rl_p" > "$rl_p.new" 2>/dev/null && mv "$rl_p.new" "$rl_p"
  fi
  printf '%s\t%s\t%s\t0\n' "$rl_id" "$rl_hook" "$rl_sess" >> "$rl_p" 2>/dev/null || true
}
trap 'rl_rc=$?; [ "$rl_rc" -eq 2 ] && refusal_log; exit "$rl_rc"' EXIT
