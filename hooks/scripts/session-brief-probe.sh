# Sourced by session-brief-slow.sh (to measure) and the tests (the pure part).
# The machine probe: how long a start of sh and of git takes right now. When a
# start takes over twice what this machine's quiet readings were, the brief
# says so and recommends what to do, as a recommendation only. Time is never
# gated; nothing here stops any work.

# probe_measure: "SH_MS GIT_MS", 20 starts of each, whole milliseconds each;
# prints nothing when the clock cannot time it.
probe_measure() {
  pm_t0=$(date +%s%N 2>/dev/null); case "$pm_t0" in ''|*[!0-9]*) return 0 ;; esac
  pm_i=0; while [ "$pm_i" -lt 20 ]; do sh -c ':'; pm_i=$((pm_i + 1)); done
  pm_t1=$(date +%s%N); pm_i=0
  while [ "$pm_i" -lt 20 ]; do git --version >/dev/null 2>&1; pm_i=$((pm_i + 1)); done
  pm_t2=$(date +%s%N)
  echo "$(( (pm_t1 - pm_t0) / 20000000 )) $(( (pm_t2 - pm_t1) / 20000000 ))"
}

# probe_quiet NOW QUIET: the lowest reading seen so far, "SH GIT" each its own
# lowest; the first reading when there is none yet.
probe_quiet() {
  echo "$1 $2" | awk '{ if (NF < 4 || $3 == "") { print $1, $2; exit } print ($1 < $3 ? $1 : $3), ($2 < $4 ? $2 : $4) }'
}

# probe_line NOW QUIET: one plain line when either start takes over twice its
# quiet time (and at least 30 ms, so a 2 ms jitter is not news); nothing otherwise.
# NOW and QUIET are "SH GIT" in milliseconds.
probe_line() {
  echo "$1 $2" | awk '
    NF < 4 { exit }
    { s = $1; g = $2; qs = $3; qg = $4; slow = 0
      if (s >= 30 && s > 2 * qs) slow = 1
      if (g >= 30 && g > 2 * qg) slow = 1
      if (!slow) exit
      printf "Machine slow to start programs: a start of sh takes %d ms (quiet: %d ms) and of git %d ms (quiet: %d ms). Recommended: let the agents and local test runs finish before starting more; if it stays slow with the machine quiet, restart it. A recommendation only, nothing is paused.\n", s, qs, g, qg }'
}
