#!/bin/sh
# The round's last step (specs/023-drive-on-work, #2128): settle each issue the round took that its landed pull
# request left open in Ready, in the same run that sees the pull requests merged, so no round looks finished with a
# loose end. An issue with a "Left:" note gets what is left filed as its own issue and is closed with a link to it; one
# with no note gets a "Settled:" comment saying it was not built this round and is Ready for the next. Prints, one a
# line on stdout, the issues it could not settle (each also said plainly on stderr); the round is not over while any is.
#
# Usage, from the project root: sh settle-round.sh COMMENTS_FILE OPEN_PULLS_FILE
# COMMENTS_FILE is the drive issue's comments (started_units' shape), OPEN_PULLS_FILE every open pull request's number.
here=$(dirname "$0")
. "$here/round-state-lib.sh"
. "$here/settle-lib.sh"
. "$here/left-lib.sh"
command -v gh >/dev/null 2>&1 || exit 0
comments=$(cat "${1:-/dev/null}" 2>/dev/null); all_open=$(cat "${2:-/dev/null}" 2>/dev/null)
started_iso=$(printf '%s\n' "$comments" | tr -d '\r' | grep -F 'sipnship-proposal {"status":"started"' | tail -n 1 | cut -f1)
[ -n "$started_iso" ] || exit 0
landed=$(started_units "$comments" | awk -F'\t' -v open="$all_open" 'BEGIN { n = split(open, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") op[a[i]] = 1 } $1 != "" && !($1 in op) { print $2 }' | tr ' ' '\n' | sed '/^$/d' | sort -un)
[ -n "$landed" ] || exit 0
facts=""
for n in $landed; do
  row=$(gh api "repos/{owner}/{repo}/issues/$n" --jq 'select(.state == "open") | [.number, ([.labels[].name | ascii_downcase | select(startswith("state:"))] | first // "" | sub("^state: ?"; ""))] | @tsv' 2>/dev/null | tr -d '\r')
  [ -n "$row" ] || continue
  noted=$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" --jq "[.[] | select(.created_at >= \"$started_iso\") | .body | select(test(\"(^|\\n)Settled:\"))] | length" 2>/dev/null | tr -d '\r')
  facts="${facts}${row}	$([ "${noted:-0}" -gt 0 ] && echo yes || echo no)
"
done
todo=$(settle_candidates "$comments" "$all_open" "$facts")
scratch=.scratch/drive; mkdir -p "$scratch" 2>/dev/null
for n in $todo; do
  title=$(gh api "repos/{owner}/{repo}/issues/$n" --jq .title 2>/dev/null | tr -d '\r')
  said=$(left_comments_say "$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" --jq '.[] | .body | gsub("\r"; "") | gsub("\n"; "\\n")' 2>/dev/null)")
  case "$said" in
    left*)
      left=${said#left	}; left=${left%%	*}
      printf '%s\n\nLeft from #%s, whose change landed and did not build this.\n' "$left" "$n" > "$scratch/settle-$n.md"
      filed=$(sh scripts/issue-open.sh "$title (left: $left)" "$scratch/settle-$n.md" state:ready 2>&1) || { echo "settle: could not file what is left of #$n: $filed" >&2; echo "$n"; continue; }
      printf 'Settled: what is left is filed as its own issue (%s), and this one is closed.\n' "$filed" > "$scratch/settle-$n-note.md"
      sh "$here/comment.sh" "$n" "$scratch/settle-$n-note.md" >/dev/null 2>&1 && gh api -X PATCH "repos/{owner}/{repo}/issues/$n" -f state=closed >/dev/null 2>&1 \
        && echo "settle: #$n closed, what is left is $filed" >&2 || { echo "settle: could not close #$n after filing $filed" >&2; echo "$n"; }
      ;;
    *)
      printf 'Settled: this round did not build it, and it is Ready for the next one. Nothing more is needed from this round.\n' > "$scratch/settle-$n-note.md"
      sh "$here/comment.sh" "$n" "$scratch/settle-$n-note.md" >/dev/null 2>&1 && echo "settle: #$n was not built this round; it stays Ready" >&2 || { echo "settle: could not settle #$n" >&2; echo "$n"; }
      ;;
  esac
done
exit 0
