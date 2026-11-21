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

# remote_lock_message MODE PID HOST RUN DIR NOW [BEAT]: the holder, in one
# line; BEAT, the last time a holder outside GitHub's runs said it lives.
remote_lock_message() { printf 'queue lock: --%s pid %s host %s run %s dir %s at %s%s\n' "$1" "$2" "$3" "${4:--}" "$5" "$6" "${7:+ beat $7}"; }

# A holder outside GitHub's runs (a terminal, an agent's session) cannot be
# checked from another checkout: its pid means nothing there. One died holding
# the lock at 2:30 PM one afternoon and a green release waited fifteen minutes,
# until a queue run by hand took it over. So such a holder renews its lock
# every QUEUE_LOCK_BEAT seconds (default 20) with a new commit, and a lock
# whose beat is older than QUEUE_LOCK_BEAT_STALE seconds (default 60) is a dead
# holder's: the next queue takes it over within a minute. A run on GitHub needs
# no beat: its own status says when it has ended.
remote_lock_beat_stale() { echo "${QUEUE_LOCK_BEAT_STALE:-60}"; }

# remote_lock_bound: how long a lock whose holder cannot be checked (another
# machine) is believed: a drain is bounded by QUEUE_DRAIN_MINUTES, so the lock
# goes stale after that plus thirty minutes, not three hours. QUEUE_LOCK_STALE
# (seconds) overrides it.
remote_lock_bound() { echo "${QUEUE_LOCK_STALE:-$(( (${QUEUE_DRAIN_MINUTES:-90} + 30) * 60 ))}"; }

# remote_lock_reason MESSAGE NOW ALIVE [STALE_SECONDS]
# Why a second queue must not start, naming the holder ("a --drain started 12
# minute(s) ago is still running (pid 4242) on DESK, Queue drain run 77"), or
# nothing when the lock is older than STALE_SECONDS (default remote_lock_bound,
# not the file lock's three hours) or ALIVE is not yes.
remote_lock_reason() {
  rl_pid=$(remote_lock_field "$1" pid); rl_at=$(remote_lock_field "$1" at)
  rl_mode=$(printf '%s\n' "$1" | head -n 1 | sed -n 's/^queue lock: \(--[a-z]*\) .*/\1/p')
  [ -n "$rl_pid" ] && [ -n "$rl_at" ] || return 0
  rl_beat=$(remote_lock_field "$1" beat)
  if [ -n "$rl_beat" ] && [ $(( $2 - rl_beat )) -gt "$(remote_lock_beat_stale)" ] 2>/dev/null; then return 0; fi
  rl_why=$(queue_lock_reason "$(printf '%s\t%s\t%s' "$rl_pid" "$rl_at" "${rl_mode:---queue}")" "$2" "$3" "${4:-$(remote_lock_bound)}")
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

# queue_busy_exit: the ending when another live queue holds the lock. A drain a
# person starts by hand needs to know theirs did not run, so it fails; a Queue
# drain GitHub started because a CI run ended finds the queue that was waiting
# for that very run, so it ends as passed (no failed run, no email).
queue_busy_exit() {
  if [ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_EVENT_NAME:-}" = workflow_run ]; then
    echo "Nothing to do here: the queue that is already at work will pick this up."
    exit 0
  fi
  exit 1
}

# remote_lock_take: before building a batch or merging, the one lock every
# queue sees. A queue that cannot reach GitHub goes on with the file lock alone
# (a failed call never blocks), and says so. Refused with the holder named when
# another queue holds it.
remote_lock_take() {
  [ -z "${QUEUE_NO_REMOTE_LOCK:-}" ] || return 0
  rt_tree=$(git rev-parse "origin/$base^{tree}" 2>/dev/null) || { say "No $base to anchor the queue lock on GitHub; going on with this machine's lock alone."; return 0; }
  rt_beat=""; [ -n "${GITHUB_RUN_ID:-}" ] || [ "${QUEUE_LOCK_BEAT:-20}" = 0 ] || rt_beat=$(date +%s)
  rt_base=$(remote_lock_message "$mode" "$$" "$(hostname 2>/dev/null)" "${GITHUB_RUN_ID:--}" "$(remote_lock_here)" "$(date +%s)")
  rt_msg=$(remote_lock_message "$mode" "$$" "$(hostname 2>/dev/null)" "${GITHUB_RUN_ID:--}" "$(remote_lock_here)" "$(date +%s)" "$rt_beat")
  rt_sha=$(gh_write api -X POST "repos/{owner}/{repo}/git/commits" -f message="$rt_msg" -f tree="$rt_tree" --jq .sha 2>"$gh_err" | tr -d '\r') || rt_sha=""
  [ -n "$rt_sha" ] || { say "Could not record the queue lock on GitHub; going on with this machine's lock alone."; return 0; }
  rt_try=0
  while :; do
    rt_try=$((rt_try + 1))
    if gh_write api -X POST "repos/{owner}/{repo}/git/refs" -f ref="refs/queue/lock" -f sha="$rt_sha" >/dev/null 2>"$gh_err"; then
      remote_lock_sha=$rt_sha; printf '%s\n' "$rt_sha" > "$flaky_dir/lock.sha" 2>/dev/null || true
      [ -z "$rt_beat" ] || remote_lock_beat "$rt_tree" "$rt_base"
      return 0
    fi
    if ! grep -qi 'already exists' "$gh_err" 2>/dev/null; then
      say "Could not take the queue lock on GitHub ($(head -n 1 "$gh_err" 2>/dev/null | tr -d '\r' | cut -c1-100)); going on with this machine's lock alone."; return 0
    fi
    rt_cur=$(remote_lock_read)
    rt_why=$(remote_lock_reason "$rt_cur" "$(date +%s)" "$(remote_lock_alive "$rt_cur")")
    if [ -n "$rt_why" ] || [ -z "$rt_cur" ] || [ "$rt_try" -ge 2 ]; then
      [ -n "$rt_why" ] || rt_why="a queue left its lock on GitHub just now"
      remote_lock_owe
      echo "Another queue is running: $rt_why. $(queue_kept_words)"
      queue_busy_exit
    fi
    # Its holder is gone or it is stale: take it over, once, and say so.
    say "Taking over a queue lock on GitHub whose holder is gone ($rt_cur)."
    remote_lock_dead_said "$rt_cur"
    gh_write api -X DELETE "repos/{owner}/{repo}/git/refs/queue/lock" >/dev/null 2>&1 || true
  done
}

# remote_lock_beat TREE MESSAGE: renew this queue's lock every QUEUE_LOCK_BEAT
# seconds while it runs, each beat a new commit whose parent is the last, so
# the ref moves only while it is still ours (a fast-forward; one taken over is
# not). Ends with the queue, or when the lock is no longer ours.
remote_lock_beat() {
  rb_parent=$$
  ( while sleep "${QUEUE_LOCK_BEAT:-20}"; do
      kill -0 "$rb_parent" 2>/dev/null || exit 0
      rb_cur=$(tr -d '\r' < "$flaky_dir/lock.sha" 2>/dev/null); [ -n "$rb_cur" ] || exit 0
      rb_new=$(gh_write api -X POST "repos/{owner}/{repo}/git/commits" -f message="$2 beat $(date +%s)" -f tree="$1" -f "parents[]=$rb_cur" --jq .sha 2>/dev/null | tr -d '\r')
      [ -n "$rb_new" ] || continue
      gh_write api -X PATCH "repos/{owner}/{repo}/git/refs/queue/lock" -f sha="$rb_new" -F force=false >/dev/null 2>&1 || exit 0
      printf '%s\n' "$rb_new" > "$flaky_dir/lock.sha"
    done ) >/dev/null 2>&1 &
  remote_lock_beat_pid=$!
}

# remote_lock_dead_said MESSAGE: a holder found dead is said where people look:
# a line on the Queue tab (notice.tsv, read by publish-state.sh) and one
# comment on the Merge queue issue. Never fatal.
remote_lock_dead_said() {
  rd_mode=$(printf '%s\n' "$1" | head -n 1 | sed -n 's/^queue lock: \(--[a-z]*\) .*/\1/p')
  rd_at=$(remote_lock_field "$1" at); rd_host=$(remote_lock_field "$1" host)
  rd_when=$(date -d "@${rd_at:-0}" '+%-I:%M %p' 2>/dev/null || date -r "${rd_at:-0}" '+%-I:%M %p' 2>/dev/null)
  rd_line="A queue run (${rd_mode:-a queue}${rd_host:+ on $rd_host}${rd_when:+, started $rd_when}) stopped without finishing; this one took its place at $(date '+%-I:%M %p' 2>/dev/null) and goes on with what it left."
  queue_notice "$rd_line"
  rd_issue=$(gh api "repos/{owner}/{repo}/issues?labels=queue&state=all&per_page=20" --jq '[.[] | select(.title == "Merge queue")] | .[0].number // empty' 2>/dev/null | tr -d '\r')
  [ -z "$rd_issue" ] || gh_write api -X POST "repos/{owner}/{repo}/issues/$rd_issue/comments" -f body="$rd_line" >/dev/null 2>&1 || true
}

# queue_notice LINE: one line for the Queue tab, said by publish-state.sh in
# front of the queue's own sentence for fifteen minutes.
queue_notice() { printf '%s\t%s\n' "$(date +%s)" "$1" > "$flaky_dir/notice.tsv" 2>/dev/null || true; }

# queue_kept_words: what a queue turned away by another tells its caller. The
# ask is kept (remote_lock_owe): the queue at work lands a green change at its
# next look, and the drain started the moment it ends lands the rest.
queue_kept_words() {
  qk_prs=$(printf '#%s ' ${prs:-} | sed 's/ $//'); [ "$qk_prs" != "#" ] || qk_prs=""
  printf '%s\n' "Your request is kept: ${qk_prs:+$qk_prs lands with the queue at work if it is green when that queue next looks, or }a drain starts the moment that queue ends and lands what is green then."
}

# remote_lock_owe: a queue turned away leaves its ask on GitHub (the ref
# refs/queue/owed), so the queue at work starts the next drain as it ends.
# One afternoon "Another queue is running" was the answer nine times, and each
# caller gave up. Never fatal.
remote_lock_owe() {
  [ -z "${QUEUE_NO_REMOTE_LOCK:-}" ] || return 0
  ro_sha=$(gh api "repos/{owner}/{repo}/git/ref/queue/lock" --jq .object.sha 2>/dev/null | tr -d '\r')
  [ -n "$ro_sha" ] || return 0
  gh_write api -X POST "repos/{owner}/{repo}/git/refs" -f ref="refs/queue/owed" -f sha="$ro_sha" >/dev/null 2>&1 || true
}

# remote_lock_owed: as a queue lets go of its lock, a queue turned away
# meanwhile is owed a drain: the ask is cleared and the Queue drain started.
remote_lock_owed() {
  [ -z "${QUEUE_NO_REMOTE_LOCK:-}" ] || return 0
  gh api "repos/{owner}/{repo}/git/ref/queue/owed" --jq .object.sha >/dev/null 2>&1 || return 0
  gh_write api -X DELETE "repos/{owner}/{repo}/git/refs/queue/owed" >/dev/null 2>&1 || true
  if [ ! -f "${QUEUE_DRAIN_WORKFLOW:-.github/workflows/queue-drain.yml}" ]; then say "A queue was turned away while this one ran; run --drain to land what it asked for."; return 0; fi
  if gh_write api -X POST "repos/{owner}/{repo}/actions/workflows/queue-drain.yml/dispatches" -f ref="${base:-main}" >/dev/null 2>&1; then
    say "A queue was turned away while this one ran; the next drain starts now and lands what is green."
  else
    say "A queue was turned away while this one ran, and the next drain could not be started; run --drain."
  fi
}

# remote_lock_release: only a lock that is still ours, so a queue that was
# taken over never releases the one that took it. Its beat ends first, and an
# ask left meanwhile starts the next drain.
remote_lock_release() {
  [ -z "${remote_lock_beat_pid:-}" ] || kill "$remote_lock_beat_pid" 2>/dev/null || true
  remote_lock_beat_pid=""
  [ -n "${remote_lock_sha:-}" ] || return 0
  rx_mine=""; [ -z "${flaky_dir:-}" ] || rx_mine=$(tr -d '\r' < "$flaky_dir/lock.sha" 2>/dev/null); [ -n "$rx_mine" ] || rx_mine=$remote_lock_sha
  rx_now=$(gh api "repos/{owner}/{repo}/git/ref/queue/lock" --jq .object.sha 2>/dev/null | tr -d '\r')
  if [ "$rx_now" = "$rx_mine" ] || [ "$rx_now" = "$remote_lock_sha" ]; then gh_write api -X DELETE "repos/{owner}/{repo}/git/refs/queue/lock" >/dev/null 2>&1 || true; fi
  remote_lock_sha=""; [ -z "${flaky_dir:-}" ] || : > "$flaky_dir/lock.sha" 2>/dev/null || true
  remote_lock_owed
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
