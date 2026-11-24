#!/bin/sh
# The merge queue's own REST budget: its guard before a round, its back-off after a refusal, and the
# cap that keeps either one from sleeping through the whole hourly reset while the drain holds its
# lock (#2513). Its own file, so state.sh (which sources this) stays under its line limit. Sourced by
# scripts/ci/merge-queue.sh (through state.sh); functions only, run from its variables: $gh_err,
# $flaky_dir and say/hhmm (state.sh), rate_wait and rate_limit_hit (rules-drain.sh).

# The REST budget only: every call the queue makes is REST, so a spent
# GraphQL budget (gh pr, gh issue, the board) never holds it. It once waited
# for the GraphQL reset with REST half full.
rate_budget() { gh api rate_limit --jq '.resources.core | "\(.remaining)\t\(.reset)"' 2>/dev/null || true; }
rate_guard() {
  rg=$(rate_budget)
  w=$(rate_wait "$rg" "$(date +%s)" "${QUEUE_RATE_FLOOR:-500}")
  [ "$w" -gt 0 ] || return 0
  rg_until=$(hhmm "${rg#*	}")
  # A wait short enough to finish inside this run is slept out as before. A longer one is never slept
  # through while this drain holds the lock (#2513): the hourly budget can take up to an hour to
  # reset, and a drain asleep that whole time once left the lock held, so no later trigger (a scheduled
  # tick, or the one a landing or a push would normally send) could run at all; a green, unheld change
  # sat for two hours before someone woke it by hand. Ending here instead says the time once, plainly,
  # releases the lock through the exit trap, and resumes on its own: the next drain any trigger starts,
  # whether that is the schedule or the next push or landing, tries again, and once the clock passes
  # the time named here it goes straight through.
  if [ "$w" -gt "${QUEUE_RATE_SLEEP_MAX:-300}" ]; then
    say "GitHub API budget is low (${rg%%	*} calls left); ending this drain now rather than holding its lock asleep until it resets at $rg_until UTC. It resumes on its own at the next trigger after that; nothing needs a by-hand request."
    exit 0
  fi
  echo "GitHub API budget is low (${rg%%	*} calls left); waiting $((w / 60 + 1)) minute(s) until it resets at $rg_until UTC."
  sleep "$w"
}
# rate_stop: after a gh call whose stderr went to $gh_err, back off when
# GitHub refused it for a rate limit. The hourly quota spent: wait for the
# reset. The secondary limit, which the budget read cannot see: 60 seconds,
# then 120, 240 and 480, and the fifth refusal stops; never retry at once. rate_ok clears the
# count after a round that went through.
rate_stop() {
  [ "$(rate_limit_hit "$(cat "$gh_err" 2>/dev/null)")" = yes ] || return 0
  : > "$gh_err"
  rg=$(rate_budget); rem=${rg%%	*}
  if [ "${rem:-1}" = 0 ]; then
    w=$(rate_wait "$rg" "$(date +%s)" 1)
    rs_until=$(hhmm "${rg#*	}")
    # As rate_guard above: never sleep through the whole reset while holding the lock (#2513).
    if [ "$w" -gt "${QUEUE_RATE_SLEEP_MAX:-300}" ]; then
      say "GitHub's hourly API quota is spent; ending this drain now rather than holding its lock asleep until it resets at $rs_until UTC. It resumes on its own at the next trigger after that."
      exit 0
    fi
    echo "GitHub's hourly API quota is spent; waiting until it resets at $rs_until UTC."
    sleep "$w"; return 0
  fi
  n=$(cat "$flaky_dir/rate.hits" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$flaky_dir/rate.hits"
  case $n in
    1) w=60 ;;
    2) w=120 ;;
    3) w=240 ;;
    4) w=480 ;;
    *) say "GitHub refused five calls for its secondary rate limit (too many concurrent or point-heavy requests from this account); stopping. Run the queue again in ten minutes, one copy, with nothing else polling."; exit 1 ;;
  esac
  say "GitHub refused the call for its secondary rate limit, which the budget read cannot see (hit $n of 5); waiting $w seconds, never retrying at once."
  sleep "$w"
}
rate_ok() { rm -f "$flaky_dir/rate.hits" 2>/dev/null || true; }
