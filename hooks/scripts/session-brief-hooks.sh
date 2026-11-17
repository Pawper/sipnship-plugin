#!/bin/sh
# Sourced by session-brief.sh: the line that names a hook that ran past half
# its time limit, from the timing log hook-timed.sh writes.

# slow_hooks_line LOG NOW
# LOG is the hooks' timing log, NOW the epoch. One plain line naming each hook
# that ran past half its time limit in the last day, or that started and never
# ended (killed for running out of time), with its slowest time; nothing when
# none did.
slow_hooks_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" '
    function epoch(t,   y, mo, d, h, mi, s, a, era, yoe, doy, doe) {
      split(t, a, /[-T:Z]/); y = a[1] + 0; mo = a[2] + 0; d = a[3] + 0; h = a[4] + 0; mi = a[5] + 0; s = a[6] + 0
      if (mo <= 2) y -= 1
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s
    }
    $1 == "start" && NF >= 5 { k = $5 "|" $3; st[k] = epoch($2); lim[k] = $4; started[k] = 1; limit[$3] = $4 }
    $1 == "end" && NF >= 6 {
      k = $6 "|" $3; delete started[k]; limit[$3] = $4
      if (epoch($2) >= now - 86400 && $5 + 0 > $4 * 500) { slow[$3] = 1; if ($5 + 0 > worst[$3] + 0) worst[$3] = $5 + 0 }
    }
    END {
      for (k in started) if (st[k] >= now - 86400 && now - st[k] > lim[k] + 5) { split(k, p, "|"); cut[p[2]] = 1 }
      for (h in slow) out = out (out == "" ? "" : ", ") sprintf("%s (%.1f s of %d)", h, worst[h] / 1000, limit[h])
      for (h in cut) if (!(h in slow)) out = out (out == "" ? "" : ", ") h " (timed out)"
      if (out != "") print "Hooks: ran past half their time in the last day: " out ". A hook that runs out of time lets the action through unchecked; the pull request checks catch most rules later (plugin/docs/hook-timeouts.md says which)."
    }'
}

# node_off_line: one plain line when this machine has no Node, or one below the
# floor in package.json, so the checks before a command are skipped
# (specs/027-hooks-in-node); nothing when Node is there.
node_off_line() {
  command -v node >/dev/null 2>&1 && {
    nf=$(sed -n 's/.*"node": *">=\{0,1\} *\([0-9]*\).*//p' "$(dirname "$0")/../../package.json" 2>/dev/null | head -n 1)
    nv=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)
    [ -n "$nv" ] && [ "$nv" -ge "${nf:-18}" ] 2>/dev/null && return 0
  }
  printf '%s
' "Hooks: the checks before each command are off on this machine because Node ${nf:-18} or newer is not installed. Everything else works, and the pull request checks still hold every rule."
}

# Hooks that ran past half their time limit in the last day, only when there are some.
s_hooks() {
  node_off_line
  hl=${CLAUDE_PROJECT_DIR:-.}/.scratch/hooks/timing.log
  [ -f "$hl" ] || return 0
  slow_hooks_line "$(tail -n 2000 "$hl" 2>/dev/null)" "$(date +%s)"
  return 0
}
