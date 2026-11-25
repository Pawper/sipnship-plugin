#!/bin/sh
# The REST half of the API budget guard (#2558), kept apart from lib.sh, which only shrinks. Sourced by
# require-gh-budget.sh and the plugin tests after lib.sh; the record it reads is the one budget_read in lib.sh gives.

# gh_script_caller COMMAND
# Who a command is when it runs one of the scripts that spend the REST hour without a visible `gh` call (#2673): check
# polling, the merge queue, the board's own reads, the drive's scripts. Prints the kind, or nothing for any other command
# (an agent's own `gh` call is counted as the agent's).
gh_script_caller() {
  case "$1" in
    *pr-checks.sh*) echo checks ;;
    *merge-queue*) echo queue ;;
    *board-now.sh*|*scripts/board/*|*board-sync.sh*) echo coordinator ;;
    *scripts/drive/*|*drive/claim.sh*) echo drive ;;
  esac
}

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

# Who spends the REST hour (#2607). GitHub does not say which caller made a request, so two things are kept on this
# machine: each fresh reading of the budget ("R", when, left, limit, reset) and each REST read or GraphQL call an agent's
# own shell made through the guard ("C", when). The brief and the nightly audit put them side by side: the hour's drop,
# and how much of it the agents' own calls explain; the rest is the app, the drive's scripts, check polling and the
# coordinator's looks, which share one token and cannot be told apart from outside.
# The file is SIPNSHIP_BUDGET_LOG, else ~/.sipnship/gh-budget-history.txt, so a session and the runner see the same one.
budget_history_file() {
  if [ -n "${SIPNSHIP_BUDGET_LOG:-}" ]; then printf '%s\n' "$SIPNSHIP_BUDGET_LOG"; else printf '%s\n' "${HOME:-.}/.sipnship/gh-budget-history.txt"; fi
}

# budget_history_add KIND [FIELDS...]: one tab-separated line; the file is cut to its last 2000 lines when it passes 3000.
budget_history_add() {
  bh_file=$(budget_history_file); bh_kind=$1; shift
  mkdir -p "$(dirname "$bh_file")" 2>/dev/null || return 0
  bh_line=$bh_kind; for bh_f in "$@"; do bh_line="$bh_line	$bh_f"; done
  printf '%s\n' "$bh_line" >> "$bh_file" 2>/dev/null || return 0
  if [ "$(wc -l < "$bh_file" 2>/dev/null | tr -d ' ')" -gt 3000 ] 2>/dev/null; then
    tail -n 2000 "$bh_file" > "$bh_file.tmp" 2>/dev/null && mv "$bh_file.tmp" "$bh_file" 2>/dev/null
  fi
  return 0
}

# budget_read_logged ROOT
# budget_read (lib.sh), and when it took a fresh reading rather than the cached one, the REST half goes in the history.
budget_read_logged() {
  brl_before=$(head -n 1 "$1/.scratch/gh-budget.txt" 2>/dev/null | cut -f1)
  brl_rec=$(budget_read "$1")
  [ -n "$brl_rec" ] || return 0
  brl_after=$(head -n 1 "$1/.scratch/gh-budget.txt" 2>/dev/null | cut -f1)
  if [ -n "$brl_after" ] && [ "$brl_after" != "$brl_before" ]; then
    budget_history_add R "$brl_after" "$(printf '%s' "$brl_rec" | cut -f4)" "$(printf '%s' "$brl_rec" | cut -f5)" "$(printf '%s' "$brl_rec" | cut -f6)"
  fi
  printf '%s\n' "$brl_rec"
}

# budget_spend_line FILE NOW [UNDER]
# The brief's second budget sentence, only when fewer than UNDER (default 2500) REST requests are left and the hour has
# two readings: how much was spent, and how many of those reads this machine's agents made.
budget_spend_line() {
  [ -f "$1" ] || return 0
  awk -F'\t' -v now="$2" -v under="${3:-2500}" '
    function commas(n,  s) { s = sprintf("%d", n); while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]$|[0-9][0-9][0-9],/, ",&", s); return s }
    $1 == "R" && NF >= 5 && now - $2 >= 0 && now - $2 < 3600 { if (n == 0 || $3 + 0 > max) max = $3 + 0; last = $3 + 0; lim = $4 + 0; n++ }
    $1 == "C" && NF >= 2 && now - $2 >= 0 && now - $2 < 3600 { calls++; kinds[($3 == "" ? "agent" : $3)]++ }
    END {
      if (n < 2 || last >= under) exit
      used = max - last; if (used <= 0) exit
      split("agent checks queue drive coordinator", order, " "); by = ""
      for (i = 1; i <= 5; i++) if (kinds[order[i]] > 0) by = by (by == "" ? "" : ", ") order[i] " " kinds[order[i]]
      printf "REST spent this hour: about %s of %s; this machine'"'"'s agents made %d of those reads%s, so the rest is the app and whatever is not counted here.\n", commas(used), commas(lim), calls, (by == "" ? "" : " (" by ")")
    }' "$1"
}

# budget_spend_by_kind FILE [SINCE]
# Every caller counted (#2863): the "C" lines of FILE (budget_history_add's
# log) with a time after SINCE (default 0, every line), summed by kind, one
# "KIND<TAB>COUNT" a line; a kind of nothing counts as "agent", as
# budget_history_add itself does. This is the local half, read by this
# machine's own scripts; drive/spend-send.sh posts it to the service, so
# Cost shows it beside the app's own count. Nothing for a missing file.
budget_spend_by_kind() {
  [ -f "$1" ] || return 0
  awk -F'\t' -v since="${2:-0}" '$1 == "C" && $2 + 0 > since { k = ($3 == "" ? "agent" : $3); n[k]++ } END { for (k in n) printf "%s\t%s\n", k, n[k] }' "$1"
}

