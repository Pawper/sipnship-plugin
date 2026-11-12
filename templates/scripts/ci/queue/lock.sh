#!/bin/sh
# One queue per repository, wherever it runs. The lock file under
# .scratch/queue is per checkout, so a drain on one runner's checkout and
# another in the main checkout never saw each other, and two batches were
# built and landed two minutes apart. The lock every queue sees is a ref on
# GitHub, refs/queue/lock, pointing at a commit whose message names the
# holder. Creating a ref that exists is refused by GitHub, so the first
# queue to ask has it, and the second is told who holds it. Sourced by
# scripts/ci/merge-queue.sh; functions only.

# remote_lock_field MESSAGE NAME: the word after NAME in the lock's message.
remote_lock_field() { printf '%s\n' "$1" | head -n 1 | awk -v k="$2" '{ for (i = 1; i < NF; i++) if ($i == k) { print $(i + 1); exit } }'; }

# remote_lock_message MODE PID HOST RUN DIR NOW: the holder, in one line.
remote_lock_message() { printf 'queue lock: --%s pid %s host %s run %s dir %s at %s\n' "$1" "$2" "$3" "${4:--}" "$5" "$6"; }

# remote_lock_reason MESSAGE NOW ALIVE [STALE_SECONDS]
# Why a second queue must not start, naming the holder ("a --drain started 12
# minute(s) ago is still running (pid 4242) on DESK, Queue drain run 77"), or
# nothing when the lock is older than STALE_SECONDS (default three hours, as
# the file lock) or ALIVE is not yes.
remote_lock_reason() {
  rl_pid=$(remote_lock_field "$1" pid); rl_at=$(remote_lock_field "$1" at)
  rl_mode=$(printf '%s\n' "$1" | head -n 1 | sed -n 's/^queue lock: \(--[a-z]*\) .*/\1/p')
  [ -n "$rl_pid" ] && [ -n "$rl_at" ] || return 0
  rl_why=$(queue_lock_reason "$(printf '%s\t%s\t%s' "$rl_pid" "$rl_at" "${rl_mode:---queue}")" "$2" "$3" "${4:-${QUEUE_LOCK_STALE:-10800}}")
  [ -n "$rl_why" ] || return 0
  rl_host=$(remote_lock_field "$1" host); rl_run=$(remote_lock_field "$1" run)
  printf '%s on %s%s\n' "$rl_why" "${rl_host:-another machine}" "$([ -z "$rl_run" ] || [ "$rl_run" = - ] || printf ', Queue drain run %s' "$rl_run")"
}

# remote_lock_here: this checkout, as a word the holder records.
remote_lock_here() { pwd | cksum | cut -d' ' -f1; }

# remote_lock_alive MESSAGE: yes unless the holder is known to be gone. A pid
# means something only in the checkout that wrote it, so it is read only there;
# a holder that is a GitHub run is gone when the run is complete; any other
# holder stays until its lock is old.
remote_lock_alive() {
  ra_pid=$(remote_lock_field "$1" pid); ra_host=$(remote_lock_field "$1" host); ra_dir=$(remote_lock_field "$1" dir); ra_run=$(remote_lock_field "$1" run)
  if [ "$ra_host" = "$(hostname 2>/dev/null)" ] && [ "$ra_dir" = "$(remote_lock_here)" ] && [ -n "$ra_pid" ]; then
    if kill -0 "$ra_pid" 2>/dev/null; then echo yes; else echo no; fi
    return 0
  fi
  if [ -n "$ra_run" ] && [ "$ra_run" != - ]; then
    if [ "$(gh api "repos/{owner}/{repo}/actions/runs/$ra_run" --jq .status 2>/dev/null | tr -d '\r')" = completed ]; then echo no; return 0; fi
  fi
  echo yes
}

# remote_lock_read: the holder's commit message, or nothing when no one holds it.
remote_lock_read() {
  rr_sha=$(gh api "repos/{owner}/{repo}/git/ref/queue/lock" --jq .object.sha 2>/dev/null | tr -d '\r') || return 0
  [ -n "$rr_sha" ] || return 0
  gh api "repos/{owner}/{repo}/git/commits/$rr_sha" --jq .message 2>/dev/null | tr -d '\r' | head -n 1
}

# remote_lock_take: before building a batch or merging, the one lock every
# queue sees. A queue that cannot reach GitHub goes on with the file lock alone
# (a failed call never blocks), and says so. Refused with the holder named when
# another queue holds it.
remote_lock_take() {
  [ -z "${QUEUE_NO_REMOTE_LOCK:-}" ] || return 0
  rt_tree=$(git rev-parse "origin/$base^{tree}" 2>/dev/null) || { say "No $base to anchor the queue lock on GitHub; going on with this machine's lock alone."; return 0; }
  rt_msg=$(remote_lock_message "$mode" "$$" "$(hostname 2>/dev/null)" "${GITHUB_RUN_ID:--}" "$(remote_lock_here)" "$(date +%s)")
  rt_sha=$(gh_write api -X POST "repos/{owner}/{repo}/git/commits" -f message="$rt_msg" -f tree="$rt_tree" --jq .sha 2>"$gh_err" | tr -d '\r') || rt_sha=""
  [ -n "$rt_sha" ] || { say "Could not record the queue lock on GitHub; going on with this machine's lock alone."; return 0; }
  rt_try=0
  while :; do
    rt_try=$((rt_try + 1))
    if gh_write api -X POST "repos/{owner}/{repo}/git/refs" -f ref="refs/queue/lock" -f sha="$rt_sha" >/dev/null 2>"$gh_err"; then
      remote_lock_sha=$rt_sha; return 0
    fi
    if ! grep -qi 'already exists' "$gh_err" 2>/dev/null; then
      say "Could not take the queue lock on GitHub ($(head -n 1 "$gh_err" 2>/dev/null | tr -d '\r' | cut -c1-100)); going on with this machine's lock alone."; return 0
    fi
    rt_cur=$(remote_lock_read)
    rt_why=$(remote_lock_reason "$rt_cur" "$(date +%s)" "$(remote_lock_alive "$rt_cur")")
    if [ -n "$rt_why" ] || [ -z "$rt_cur" ] || [ "$rt_try" -ge 2 ]; then
      [ -n "$rt_why" ] || rt_why="a queue left its lock on GitHub just now"
      echo "Another queue is running: $rt_why. Wait for it to finish rather than starting a second one; a lock left by a crash ends on its own after three hours."
      exit 1
    fi
    # Its holder is gone or it is stale: take it over, once.
    say "Taking over a queue lock on GitHub whose holder is gone ($rt_cur)."
    gh_write api -X DELETE "repos/{owner}/{repo}/git/refs/queue/lock" >/dev/null 2>&1 || true
  done
}

# remote_lock_release: only a lock that is still ours, so a queue that was
# taken over never releases the one that took it.
remote_lock_release() {
  [ -n "${remote_lock_sha:-}" ] || return 0
  rx_now=$(gh api "repos/{owner}/{repo}/git/ref/queue/lock" --jq .object.sha 2>/dev/null | tr -d '\r')
  if [ "$rx_now" = "$remote_lock_sha" ]; then gh_write api -X DELETE "repos/{owner}/{repo}/git/refs/queue/lock" >/dev/null 2>&1 || true; fi
  remote_lock_sha=""
}

# batch_members_open BATCH_PR MEMBERS: just before a batch merges, every member
# must still be open. One that landed meanwhile (another queue, a serial merge)
# makes the batch a second landing of the same change; the batch is closed and
# the run ends, to be built again from what is still unmerged. Returns 1 then.
batch_members_open() {
  for bo_pr in $(printf '%s\n' "$2" | cut -f1); do
    bo_state=$(gh api "repos/{owner}/{repo}/pulls/$bo_pr" --jq '.state + " " + (.merged | tostring)' 2>/dev/null | tr -d '\r')
    case "$bo_state" in
      "open "*|"") ;;
      *) close_pr "$1" "A pull request in this batch ($bo_pr) is no longer open, so the batch is not merged: it would land the same change twice. The next batch is built from what is still unmerged."; return 1 ;;
    esac
  done
}
