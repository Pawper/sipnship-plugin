#!/bin/sh
# The pure part of the mock check, sourced by scripts/ci/mock-check.sh and
# the tests. Needs only sh and awk.
# A mocks.txt line is "NAME UI_PATH MOCK_PATH [MOCK_PATH...]": a screen's UI
# file or glob, then every file that is its mock (a light and a dark file,
# and the script that generates them). "unmocked PATH" declares a UI file
# with no mock on purpose; "generator PATH" is a file every generator
# shares, whose change counts as every mock changing. A glob's * reaches
# across folders, as in a case pattern.

# mock_lines TEXT: "NAME<TAB>UI<TAB>MOCK MOCK..." per mapping line.
mock_lines() {
  printf '%s\n' "$1" | tr -d '\r' | awk '!/^[[:space:]]*(#|$)/ && NF >= 3 && $1 != "unmocked" && $1 != "generator" {
    m = $3; for (i = 4; i <= NF; i++) m = m " " $i; printf "%s\t%s\t%s\n", $1, $2, m }'
}

# mock_keyword WORD TEXT: the PATH of every "WORD PATH" line.
mock_keyword() {
  printf '%s\n' "$2" | tr -d '\r' | awk -v w="$1" '$1 == w && NF >= 2 { print $2 }'
}

# mock_stale_after TEXT: N from a "# stale-after: N" line, 20 by default.
mock_stale_after() {
  msa=$(printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^#[[:space:]]*stale-after:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
  echo "${msa:-20}"
}

# any_matches PATHS GLOBS: true when any path (one per line) is or matches
# any glob (space-separated).
any_matches() {
  am_paths=$(printf '%s\n' "$1" | tr -d '\r')
  set -f
  for am_g in $2; do
    for am_p in $am_paths; do
      # shellcheck disable=SC2254
      case "$am_p" in $am_g) set +f; return 0 ;; esac
    done
  done
  set +f
  return 1
}

# mock_missing CHANGED TEXT: the NAME of every line whose UI changed and
# none of whose mocks (nor a shared generator) did, one per line.
mock_missing() {
  mm_gen=$(mock_keyword generator "$2" | paste -sd' ' -)
  if [ -n "$mm_gen" ] && any_matches "$1" "$mm_gen"; then return 0; fi
  # a file declared unmocked never asks for a mock, even under a mapped glob
  mm_un=$(mock_keyword unmocked "$2" | paste -sd' ' -)
  mm_ch=$(printf '%s\n' "$1" | tr -d '\r' | while IFS= read -r mm_p; do
    [ -n "$mm_p" ] || continue
    [ -n "$mm_un" ] && any_matches "$mm_p" "$mm_un" && continue
    printf '%s\n' "$mm_p"
  done)
  mock_lines "$2" | while IFS='	' read -r mm_n mm_ui mm_mocks; do
    any_matches "$mm_ch" "$mm_ui" || continue
    any_matches "$1" "$mm_mocks" || printf '%s\n' "$mm_n"
  done
}

# mock_unmapped CHANGED TEXT: each changed file in a folder that a line's UI
# path names, with the same extension, that no line maps and no "unmocked"
# line declares.
mock_unmapped() {
  mu_ui=$(mock_lines "$2" | awk -F'\t' '{ print $2 }')
  mu_all=$(printf '%s\n%s\n' "$mu_ui" "$(mock_keyword unmocked "$2")" | sed '/^$/d' | paste -sd' ' -)
  mu_dirs=$(printf '%s\n' "$mu_ui" | awk 'NF { d = $0; sub(/[*?[].*$/, "x", d); sub(/\/[^\/]*$/, "", d); e = $0; sub(/.*\./, "", e); print d "\t" e }' | sort -u)
  printf '%s\n' "$1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | while IFS= read -r mu_p; do
    any_matches "$mu_p" "$mu_all" && continue
    mu_d=${mu_p%/*}; mu_e=${mu_p##*.}
    [ "$mu_d" != "$mu_p" ] || continue
    if printf '%s\n' "$mu_dirs" | grep -qxF "$mu_d	$mu_e"; then printf '%s\n' "$mu_p"; fi
  done
}

# mock_escape TEXT: the reason in a "Mock: unchanged, <reason>" line,
# nothing otherwise.
mock_escape() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[[:space:]]*[Mm]ock:[[:space:]]*unchanged,[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' | head -n 1
}

# stale_mocks COUNTS N: COUNTS is "NAME<TAB>COMMITS", the commits to a
# screen's UI since its mock last changed. Print "NAME: K commits" for each
# over N, worst first.
stale_mocks() {
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF >= 2 && $2 + 0 > n + 0 { printf "%s\t%s: %s commits\n", $2, $1, $2 }' | sort -t'	' -k1,1nr | cut -f2-
}
