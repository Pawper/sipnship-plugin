#!/bin/sh
# The REST half of the API budget guard (#2558), kept apart from lib.sh, which only shrinks. Sourced by
# require-gh-budget.sh and the plugin tests after lib.sh; the record it reads is the one budget_read in lib.sh gives.

# gh_rest_read_reason COMMAND
# Print "gh api PATH" for the first gh api call in COMMAND that only reads over
# REST (#2558): a path that is not graphql or rate_limit, with no write method
# and no body flag. A write is what lands or recovers work, so it is never named
# here; rate_limit is the free reading the guard itself needs. Nothing otherwise.
gh_rest_read_reason() {
  split_commands "$(printf '%s' "$1" | sed 's/{owner}/OWNER/g; s/{repo}/REPO/g')" | awk '
    {
      n = split($0, t, /[ \t]+/)
      for (i = 1; i < n; i++) if (t[i] == "gh" && t[i + 1] == "api") {
        path = ""; write = 0
        for (j = i + 2; j <= n; j++) {
          a = t[j]
          if (a == "-X" || a == "--method") { m = toupper(t[j + 1]); if (m != "GET") write = 1; j++; continue }
          if (a ~ /^--method=/) { if (toupper(substr(a, 10)) != "GET") write = 1; continue }
          if (a == "-f" || a == "-F" || a == "--field" || a == "--raw-field" || a == "--input" || a ~ /^-[fF]/ || a ~ /^--(field|raw-field|input)=/) { write = 1; continue }
          if (a ~ /^-/) continue
          if (path == "") path = a
        }
        if (path == "" || path == "graphql" || path ~ /^rate_limit/ || write) next
        print "gh api " path; exit
      }
    }'
}

# budget_rest_low RECORD [FLOOR]
# "yes" when fewer than FLOOR (default 150) REST requests are left; "no" otherwise or for an empty record.
budget_rest_low() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v floor="${2:-150}" '
    NR == 1 && NF >= 6 && $4 != "" && $4 + 0 < floor { low = 1 } END { print (low ? "yes" : "no") }'
}

# budget_rest_line RECORD NOW
# One sentence for a refused REST read: how many are left and when the hour returns them.
budget_rest_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" '
    NR == 1 && NF >= 6 && $4 != "" {
      mins = int(($6 - now + 59) / 60); if (mins < 0) mins = 0
      printf "REST %d of %d left, back at %s (in %d min).", $4, $5, sprintf("%02d:%02dZ", int(($6 % 86400) / 3600), int(($6 % 3600) / 60)), mins
    }'
}

