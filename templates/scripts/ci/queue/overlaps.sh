#!/bin/sh
# The queue's overlap words: when it picks pull requests, each one that
# edits a file another open pull request also edits is named in the row's
# words ("#12 Overlaps #14 and #15 in garden.ts"). Functions only. The words
# come from hotspots-lib.sh; REST only, forty pull requests at most.
#
# A drain reads the board many times an hour, often beside a batch's own
# run, and on a machine where a process start is slow every start is paid by
# every check. So the reading is cheap by design: one list call, a pull
# request's files fetched only when its head has moved since the last
# reading, and one awk to choose from the cache. The drain says what its
# reading cost, as a count of processes the machine started, never a time.

[ -f "$here/hotspots-lib.sh" ] && . "$here/hotspots-lib.sh"

# pr_files_cache: where the files each pull request changed are kept, one
# line "NUMBER<TAB>HEAD SHA<TAB>PATH".
pr_files_cache() { printf '%s\n' "${flaky_dir:-${TMPDIR:-/tmp}}/pr-files.tsv"; }

# pr_files_fetch NUMBER SHA: read one pull request's files from GitHub and
# keep them in the cache.
pr_files_fetch() {
  pf_rows=$(gh api "repos/{owner}/{repo}/pulls/$1/files?per_page=100" --jq ".[].filename | \"$1\t$2\t\" + ." 2>/dev/null | tr -d '\r')
  [ -z "$pf_rows" ] || printf '%s\n' "$pf_rows" >> "$(pr_files_cache)"
}

# queue_open_files
# "NUMBER<TAB>PATH" for every open pull request's files: one call for the
# list, and one more only for each pull request whose head is not cached.
queue_open_files() {
  qo_cache=$(pr_files_cache)
  qo_open=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=40" --jq '.[] | "\(.number)\t\(.head.sha)"' 2>/dev/null | tr -d '\r')
  [ -n "$qo_open" ] || return 0
  [ -f "$qo_cache" ] || : > "$qo_cache" 2>/dev/null || true
  qo_miss=$(printf '%s\n' "$qo_open" | awk -F'\t' -v c="$qo_cache" 'BEGIN { while ((getline l < c) > 0) { split(l, a, "\t"); have[a[1] "\t" a[2]] = 1 } } !(($1 "\t" $2) in have)' 2>/dev/null) || qo_miss=$qo_open
  while IFS="$(printf '\t')" read -r qo_n qo_sha; do
    if [ -n "$qo_n" ]; then pr_files_fetch "$qo_n" "$qo_sha"; fi
  done <<QUEUE_MISS
$qo_miss
QUEUE_MISS
  printf '%s\n' "$qo_open" | awk -F'\t' 'NR == FNR { open[$1 "\t" $2] = 1; next } (($1 "\t" $2) in open) { print $1 "\t" $3 }' - "$qo_cache"
}

# pr_files_of NUMBER SHA: one pull request's files, from the cache, read
# from GitHub once when its head is not there.
pr_files_of() {
  pf_cache=$(pr_files_cache)
  [ -n "$(awk -F'\t' -v n="$1" -v s="$2" '$1 == n && $2 == s { print "y"; exit }' "$pf_cache" 2>/dev/null)" ] || pr_files_fetch "$1" "$2"
  awk -F'\t' -v n="$1" -v s="$2" '$1 == n && $2 == s { print $3 }' "$pf_cache" 2>/dev/null
}

# reading_mark: the number the machine's next process gets, read by a builtin
# (one fork, no exec). The difference between two marks is how many
# processes the machine started between them. Nothing when the shell cannot
# say.
reading_mark() { ( read -r rm_x _ < /proc/self/stat 2>/dev/null && printf '%s\n' "$rm_x" ); }

# reading_cost MARK SECONDS: "N processes in S seconds" since the mark and
# the clock reading, or nothing. The count is every process the machine
# started in that time, so it is an upper bound on the reading's own.
reading_cost() {
  rc_now=$(reading_mark)
  case "$1$rc_now" in ''|*[!0-9]*) return 0 ;; esac
  [ "$rc_now" -gt "$1" ] || return 0
  printf '%s processes in %s seconds\n' $(( rc_now - $1 - 1 )) $(( $(date +%s) - $2 ))
}

# queue_overlap_lines PICK
# PICK is pull request numbers, one a line or space separated. One line for
# each file a picked pull request edits that another open one edits too.
queue_overlap_lines() {
  command -v hotspot_overlap_rows >/dev/null 2>&1 || return 0
  qo_all=$(queue_open_files)
  [ -n "$qo_all" ] || return 0
  # One awk for every picked pull request, not a set of small tools for each:
  # "PICK<TAB>PATH<TAB>NUMBERS" for each path a pick shares with another.
  set -- $1
  printf '%s\n' "$qo_all" | awk -F'\t' -v picks="$*" '
    { sub(/\r$/, ""); gsub(/\\/, "/", $2); k = $1 SUBSEP $2
      if (!(k in seen)) { seen[k] = 1; mine[$1] = mine[$1] "\n" $2; by[$2] = by[$2] " " $1 } }
    END {
      np = split(picks, P, " ")
      for (i = 1; i <= np; i++) {
        nf = split(mine[P[i]], F, "\n")
        for (j = 2; j <= nf; j++) {
          others = ""; m = split(by[F[j]], N, " ")
          for (x = 1; x <= m; x++) if (N[x] != P[i]) others = others " " N[x]
          if (others != "") { sub(/^ /, "", others); print P[i] "\t" F[j] "\t" others }
        }
      }
    }' | while IFS="$(printf '\t')" read -r qo_pr qo_p qo_nums; do
    if [ -n "$qo_p" ]; then printf '  #%s %s\n' "$qo_pr" "$(hotspot_overlap_say "$qo_p" "$qo_nums")"; fi
  done
}

# say_round_pick ROUND COUNT PICK
# The drain's "round N: green pull requests" line, then the overlaps, then
# what reading the board cost.
say_round_pick() {
  say "round $1: $2 green pull request(s): $(printf '%s' "$3" | tr '\n' ' ')"
  sr_mark=$(reading_mark); sr_at=$(date +%s)
  queue_overlap_lines "$3" | while IFS= read -r sr_line; do say "$sr_line"; done
  sr_cost=$(reading_cost "$sr_mark" "$sr_at")
  [ -z "$sr_cost" ] || say "  reading the other open pull requests took $sr_cost"
}
