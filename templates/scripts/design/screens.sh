#!/bin/sh
# When was each screen last compared across platforms by eye? A file-pair
# check says which screens changed; it never says that the Android Today
# looks nothing like the web's. design/screens.txt records the day a
# person compared each pair (from scripts/ci/parity.txt), and the session
# brief names the pairs never compared or older than 14 days.
# Usage:
#   sh scripts/design/screens.sh list            every pair with its last comparison
#   sh scripts/design/screens.sh stale [DAYS]    the pairs due (default 14 days)
#   sh scripts/design/screens.sh compare NAME... record today's comparison
here=$(dirname "$0")
. "$here/design-lib.sh"
file=design/screens.txt
pairs_file=scripts/ci/parity.txt
[ -f "$pairs_file" ] || { echo "No $pairs_file: no screen pairs to compare."; exit 0; }
today=$(date +%Y-%m-%d)
cmd=${1:-list}; shift 2>/dev/null || true
pairs=$(parity_pairs "$(cat "$pairs_file")")
records=$(cat "$file" 2>/dev/null || true)
case "$cmd" in
  list)
    printf '%s\n' "$pairs" | awk -F'\t' '{ print $1 }' | while IFS= read -r n; do
      d=$(printf '%s\n' "$records" | awk -v n="$n" '!/^[[:space:]]*#/ && $1 == n { d = $2; b = $3 } END { if (d != "") print d " by " b; else print "never" }')
      printf '%-24s %s\n' "$n" "$d"
    done ;;
  stale)
    out=$(stale_screens "$pairs" "$records" "$today" "${1:-14}")
    if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "Every screen pair was compared in the last ${1:-14} days."; fi ;;
  compare)
    [ $# -gt 0 ] || { echo "Usage: sh scripts/design/screens.sh compare NAME [NAME...]" >&2; exit 2; }
    by=$(git config user.name 2>/dev/null | tr ' ' '-'); by=${by:-someone}
    for n in "$@"; do
      printf '%s\n' "$pairs" | awk -F'\t' '{ print $1 }' | grep -qx "$n" || { echo "No pair named $n in $pairs_file." >&2; exit 2; }
      [ -f "$file" ] || printf '# NAME DATE BY: when each screen pair was last compared by eye.\n' > "$file"
      grep -v "^$n " "$file" > "$file.new" 2>/dev/null || true
      printf '%s %s %s\n' "$n" "$today" "$by" >> "$file.new"
      mv "$file.new" "$file"
      echo "$n: compared $today by $by"
    done ;;
  *) echo "Usage: sh scripts/design/screens.sh list | stale [DAYS] | compare NAME..." >&2; exit 2 ;;
esac
