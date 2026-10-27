#!/bin/sh
# When was each screen last compared by eye? A file-pair check says which
# screens changed; it never says that the Android Today looks nothing like
# the web's, nor that the built screen drifted from its mock.
# design/screens.txt holds two kinds of line, dated the owner's local day:
#   NAME DATE BY        a screen pair (scripts/ci/parity.txt) compared across platforms
#   NAME DATE BY mock   a screen (scripts/ci/mocks.txt) compared with its mock,
#                       after looking at the side-by-side the screens job attached
# The session brief names the screens never compared or older than 14 days.
# CI records nothing; a person does, after looking.
# Usage:
#   sh scripts/design/screens.sh list                    every screen with its last comparison
#   sh scripts/design/screens.sh stale [DAYS]            the screens due (default 14 days)
#   sh scripts/design/screens.sh compare NAME...         record today's cross-platform comparison
#   sh scripts/design/screens.sh compare --mock NAME...  record today's mock-vs-build comparison
here=$(dirname "$0")
. "$here/design-lib.sh"
[ -f "$here/../ci/mock-lib.sh" ] && . "$here/../ci/mock-lib.sh"
file=design/screens.txt
pairs_file=scripts/ci/parity.txt
mocks_file=scripts/ci/mocks.txt
pairs=""; mocked=""; routed=""
[ -f "$pairs_file" ] && pairs=$(parity_pairs "$(cat "$pairs_file")")
[ -f "$mocks_file" ] && command -v mock_lines >/dev/null 2>&1 && mocked=$(mock_lines "$(cat "$mocks_file")") && routed=$(mock_routes "$(cat "$mocks_file")")
[ -n "$pairs" ] || [ -n "$mocked" ] || { echo "No $pairs_file and no $mocks_file: no screens to compare."; exit 0; }
today=$(date +%Y-%m-%d)
cmd=${1:-list}; shift 2>/dev/null || true
records=$(cat "$file" 2>/dev/null || true)
names() { printf '%s\n' "$1" | awk -F'\t' 'NF && $1 != "" { print $1 }'; }
# last NAME KIND: "DATE by BY", or "never"
last() { printf '%s\n' "$records" | tr -d '\r' | awk -v n="$1" -v k="$2" '!/^[[:space:]]*#/ && $1 == n && ((k == "mock") == ($4 == "mock")) { d = $2; b = $3 } END { if (d != "") print d " by " b; else print "never" }'; }
case "$cmd" in
  list)
    names "$pairs" | while IFS= read -r n; do printf '%-24s %s\n' "$n" "$(last "$n" "")"; done
    names "$mocked" | while IFS= read -r n; do printf '%-24s %s\n' "$n (mock)" "$(last "$n" mock)"; done ;;
  stale)
    out=$( [ -z "$pairs" ] || stale_screens "$pairs" "$records" "$today" "${1:-14}"
           # only the screens with a route, which the screens job renders
           [ -z "$routed" ] || stale_screens "$routed" "$records" "$today" "${1:-14}" mock | sed 's/: / (mock): /')
    if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "Every screen was compared in the last ${1:-14} days."; fi ;;
  compare)
    kind=""; list=""
    for a in "$@"; do if [ "$a" = "--mock" ]; then kind=mock; else list="$list $a"; fi; done
    # shellcheck disable=SC2086
    set -- $list
    [ $# -gt 0 ] || { echo "Usage: sh scripts/design/screens.sh compare [--mock] NAME..." >&2; exit 2; }
    by=$(git config user.name 2>/dev/null | tr ' ' '-'); by=${by:-someone}
    for n in "$@"; do
      if [ "$kind" = mock ]; then
        names "$mocked" | grep -qx "$n" || { echo "No screen named $n in $mocks_file." >&2; exit 2; }
      else
        names "$pairs" | grep -qx "$n" || { echo "No pair named $n in $pairs_file." >&2; exit 2; }
      fi
      mkdir -p design; [ -f "$file" ] || printf '# NAME DATE BY [mock]: when each screen was last compared by eye.\n' > "$file"
      awk -v n="$n" -v k="$kind" '!($1 == n && ((k == "mock") == ($4 == "mock")))' "$file" > "$file.new"
      printf '%s %s %s%s\n' "$n" "$today" "$by" "${kind:+ mock}" >> "$file.new"
      mv "$file.new" "$file"
      echo "$n: compared${kind:+ with its mock} $today by $by"
    done ;;
  *) echo "Usage: sh scripts/design/screens.sh list | stale [DAYS] | compare [--mock] NAME..." >&2; exit 2 ;;
esac
