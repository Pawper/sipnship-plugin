#!/bin/sh
# queue_log_post: the queue's own standing-log writes, split out of state.sh
# (which was over its line limit) so each file stays small. Sourced by
# scripts/ci/queue/state.sh; functions only, run from merge-queue.sh's
# variables ($here).

# queue_log_post KIND ISSUE LINE: a line the queue writes to one of its own
# standing logs (the merge queue's issue), through the same helper every
# other log writer uses (log-post-lib.sh, #2319): the service, as the app,
# when this project is connected, else gh_write as before. A project that has
# not synced the template yet (no scripts/ci/log-post-lib.sh) keeps the old
# path, so this is never a hard dependency.
queue_log_post() {
  [ -n "${QUEUE_LOG_POST_LOADED:-}" ] || { [ -f "$here/log-post-lib.sh" ] && . "$here/log-post-lib.sh" && QUEUE_LOG_POST_LOADED=1; }
  if [ "${QUEUE_LOG_POST_LOADED:-}" = 1 ]; then
    qlp_file=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/queue-log-post-$$")
    printf '%s\n' "$3" > "$qlp_file"
    log_post "$1" "$2" "$qlp_file" >/dev/null 2>&1 || true
    rm -f "$qlp_file" 2>/dev/null || true
  else
    gh_write api -X POST "repos/{owner}/{repo}/issues/$2/comments" -f body="$3" >/dev/null 2>&1 || true
  fi
}
