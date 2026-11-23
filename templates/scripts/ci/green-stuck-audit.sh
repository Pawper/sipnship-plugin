#!/bin/sh
# For the nightly audit: a change green on every check and not held that has sat open for more
# than GREEN_STUCK_MINUTES (default 30) is one line, "#PR: green for N minutes and not landed."
# The queue lands a green, unheld change within minutes, so one sitting longer means a drain did
# not land it and nothing retried (#2398). REST only (the pulls list and each head's check runs);
# prints nothing when all is well or GitHub cannot be asked. Needs gh signed in.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/waiting-hold-lib.sh"

limit=${GREEN_STUCK_MINUTES:-30}
now=${GREEN_STUCK_NOW:-$(date -u +%s)}

# green_since CHECKS: CHECKS is one "STATUS<TAB>CONCLUSION<TAB>COMPLETED_AT" line a check run. Prints the epoch the
# last one finished when every run completed and none failed, nothing otherwise (no run at all is not green).
green_since() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 3 {
      n++
      if ($1 != "completed" || ($2 != "success" && $2 != "skipped" && $2 != "neutral")) bad = 1
      if ($3 > last) last = $3
    }
    END { if (n > 0 && !bad) print last }' | while read -r gs_t; do date -u -d "$gs_t" +%s 2>/dev/null; done
}

pairs=$(open_pr_pairs | awk -F'\t' '$2 == "free" { print $1 }')
[ -n "$pairs" ] || exit 0
for gs_pr in $pairs; do
  gs_sha=$(gh api "repos/{owner}/{repo}/pulls/$gs_pr" --jq '.head.sha' 2>/dev/null | tr -d '\r')
  [ -n "$gs_sha" ] || continue
  gs_runs=$(gh api "repos/{owner}/{repo}/commits/$gs_sha/check-runs?per_page=100" --jq '.check_runs[] | [.status, (.conclusion // ""), (.completed_at // "")] | @tsv' 2>/dev/null)
  gs_at=$(green_since "$gs_runs")
  [ -n "$gs_at" ] || continue
  gs_min=$(( (now - gs_at) / 60 ))
  [ "$gs_min" -gt "$limit" ] || continue
  printf '#%s: green for %s minutes and not landed.\n' "$gs_pr" "$gs_min"
done
exit 0
