#!/bin/sh
# For the nightly audit: a held change's question lives as a comment on the issue it closes
# (spec 024's guided review), so two problems leave it with nowhere to go, one line each:
#  - it closes no issue: "#PR: closes no issue, so its question has nowhere to live."
#  - it shares its issue with another held change, where the second usually replaces the
#    first: "#PR and #PR: both close #N, so the second usually replaces the first."
# REST only; prints nothing when all is well or GitHub cannot be asked. Needs gh signed in.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/waiting-hold-lib.sh"

pairs=$(open_pr_pairs | awk -F'\t' '$2 == "held"')
[ -n "$pairs" ] || exit 0

refs=""
while IFS="$(printf '\t')" read -r hc_pr hc_hold hc_body; do
  [ -n "$hc_pr" ] || continue
  hc_refs=$(closed_refs "$hc_body")
  if [ -z "$hc_refs" ]; then
    printf '#%s: closes no issue, so its question has nowhere to live.\n' "$hc_pr"
  fi
  for hc_ref in $hc_refs; do
    refs="$refs$hc_ref	$hc_pr
"
  done
done <<EOF
$pairs
EOF

printf '%s' "$refs" | awk -F'\t' '
  NF >= 2 { n[$1] = (n[$1] != "") ? n[$1] "," $2 : $2; if (!seen[$1]++) order[++k] = $1 }
  END {
    for (i = 1; i <= k; i++) {
      issue = order[i]
      m = split(n[issue], prs, ",")
      if (m > 1) {
        line = "#" prs[1]
        for (j = 2; j <= m; j++) line = line " and #" prs[j]
        verb = (m == 2) ? "both close" : "all close"
        printf "%s: %s #%s, so the second usually replaces the first.\n", line, verb, issue
      }
    }
  }'
exit 0
