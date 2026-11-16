#!/bin/sh
# Runs one hook script and writes two lines to the project's local timing log
# (.scratch/hooks/timing.log): one when it starts and one when it ends, with the
# milliseconds it took. A hook that is killed for running out of time leaves
# only its start line, so a slow or stuck one can be named afterwards.
#
#   sh hook-timed.sh LIMIT_SECONDS SCRIPT [ARGS...]
#
# Standard input goes to the script unchanged, and so do its output and its
# exit status: this wrapper decides nothing. Lines, tab-separated:
#   start  TIME  NAME  LIMIT  PID
#   end    TIME  NAME  LIMIT  MILLISECONDS  PID
# HOOK_LOG=0 turns the log off; the hook still runs. The file stays on this
# machine in the ignored scratch folder, and is cut to its newest lines when
# it grows long.
here=$(dirname "$0")
limit=$1; script=$2; shift 2 2>/dev/null || exit 0
[ -f "$here/$script" ] || exit 0

# now_ms: milliseconds since the epoch where date can say, else whole seconds.
now_ms() {
  nm_n=$(date +%s%N 2>/dev/null)
  case "$nm_n" in
    ''|*[!0-9]*) printf '%s000\n' "$(date +%s)" ;;
    *) printf '%s\n' "$((nm_n / 1000000))" ;;
  esac
}

# timing_log_dir: the project's scratch folder for hook logs, or nothing.
timing_log_dir() {
  td_root=${CLAUDE_PROJECT_DIR:-.}
  { [ -d "$td_root/.git" ] || [ -f "$td_root/.git" ]; } || return 1
  mkdir -p "$td_root/.scratch/hooks" 2>/dev/null || return 1
  printf '%s/.scratch/hooks\n' "$td_root"
}

log_dir=""
[ "${HOOK_LOG:-1}" = 0 ] || log_dir=$(timing_log_dir) || log_dir=""
name=$(basename "$script" .sh)
t0=$(now_ms)
if [ -n "$log_dir" ]; then
  printf 'start\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$limit" "$$" >> "$log_dir/timing.log" 2>/dev/null || true
fi

tmp_in=$(mktemp 2>/dev/null) || tmp_in=""
if [ -n "$tmp_in" ]; then
  cat > "$tmp_in"
  sh "$here/$script" "$@" < "$tmp_in"
  rc=$?
  rm -f "$tmp_in" 2>/dev/null || true
else
  sh "$here/$script" "$@"
  rc=$?
fi

if [ -n "$log_dir" ]; then
  t1=$(now_ms)
  printf 'end\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$limit" "$((t1 - t0))" "$$" >> "$log_dir/timing.log" 2>/dev/null || true
  if [ "$(wc -l < "$log_dir/timing.log" 2>/dev/null | tr -d ' ')" -gt 4000 ] 2>/dev/null; then
    tail -n 2000 "$log_dir/timing.log" > "$log_dir/timing.log.new" 2>/dev/null && mv "$log_dir/timing.log.new" "$log_dir/timing.log" 2>/dev/null || true
  fi
fi
exit "$rc"
