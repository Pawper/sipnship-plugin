#!/bin/sh
# The queue's overlap words: when it picks pull requests, each one that
# edits a file another open pull request also edits is named in the row's
# words ("#12 Overlaps #14 and #15 in garden.ts"). Functions only. The words
# come from hotspots-lib.sh; REST only, forty pull requests at most.

[ -f "$here/hotspots-lib.sh" ] && . "$here/hotspots-lib.sh"

# queue_open_files
# "NUMBER<TAB>PATH" for every open pull request's files.
queue_open_files() {
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=40" --jq '.[].number' 2>/dev/null | while read -r qo_n; do
    gh api "repos/{owner}/{repo}/pulls/$qo_n/files?per_page=100" --jq ".[].filename | \"$qo_n\t\" + ." 2>/dev/null
  done
}

# queue_overlap_lines PICK
# PICK is pull request numbers, one a line or space separated. One line for
# each file a picked pull request edits that another open one edits too.
queue_overlap_lines() {
  command -v hotspot_overlap_rows >/dev/null 2>&1 || return 0
  qo_all=$(queue_open_files)
  [ -n "$qo_all" ] || return 0
  for qo_pr in $1; do
    qo_mine=$(printf '%s\n' "$qo_all" | awk -F'\t' -v n="$qo_pr" '$1 == n { print $2 }')
    qo_rest=$(printf '%s\n' "$qo_all" | awk -F'\t' -v n="$qo_pr" '$1 != n')
    hotspot_overlap_rows "$qo_mine" "$qo_rest" 1 | while IFS="$(printf '\t')" read -r qo_p qo_nums; do
      if [ -n "$qo_p" ]; then printf '  #%s %s\n' "$qo_pr" "$(hotspot_overlap_say "$qo_p" "$qo_nums")"; fi
    done
  done
}

# say_round_pick ROUND COUNT PICK
# The drain's "round N: green pull requests" line, then the overlaps.
say_round_pick() {
  say "round $1: $2 green pull request(s): $(printf '%s' "$3" | tr '\n' ' ')"
  queue_overlap_lines "$3" | while IFS= read -r sr_line; do say "$sr_line"; done
}
