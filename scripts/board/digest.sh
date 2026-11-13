#!/bin/sh
# Save and show the board digest. Local only: no network.
#
#   sh digest.sh save     read reader lines on standard input, each
#                         "NUMBER | BALL | NEXT | BLOCKER | SUMMARY", merge
#                         them into .scratch/board/digest.tsv stamped with
#                         each item's current last-updated time, and drop
#                         items that are no longer open.
#   sh digest.sh show     print the digest for a person or an orchestrator:
#                         one line per open item, the ones waiting on
#                         someone first.
#   sh digest.sh goals    print the goals the digest adds to a proposal.
#   sh digest.sh no-question N
#                         a reader re-read issue N and found no open question:
#                         its line says so, stamped with its current time, so
#                         mark-waiting is not proposed for it until it changes.
here=$(dirname "$0")
. "$here/board-lib.sh"

dir=.scratch/board
facts=""; [ -f "$dir/facts.tsv" ] && facts=$(cat "$dir/facts.tsv")
digest=""; [ -f "$dir/digest.tsv" ] && digest=$(cat "$dir/digest.tsv")

case "${1:-show}" in
  save)
    [ -n "$facts" ] || { echo "No board facts yet; run read.sh first." >&2; exit 1; }
    new=$(cat)
    merged=$(merge_digest "$digest" "$new" "$facts")
    printf '%s\n' "$merged" > "$dir/digest.tsv.new" && mv "$dir/digest.tsv.new" "$dir/digest.tsv"
    fresh=$(digest_freshness "$facts" "$merged")
    echo "Saved. ${fresh%%	*} of ${fresh##*	} open items have a current summary."
    ;;
  show)
    [ -n "$digest" ] || { echo "No digest yet. Run read.sh, give the batches to readers, and save what they return."; exit 0; }
    fresh=$(digest_freshness "$facts" "$digest")
    echo "Digest: ${fresh%%	*} of ${fresh##*	} open items current."
    printf '%s\n' "$digest" | awk -F'\t' '
      NF >= 7 {
        rank = ($4 == "owner") ? 1 : ($4 == "reviewer") ? 2 : ($4 == "service") ? 3 : ($4 == "agent") ? 4 : 5
        line = sprintf("#%s (%s) ball %s | next: %s | blocker: %s | %s", $1, $2, $4, $5, $6, $7)
        out[rank, ++c[rank]] = line
      }
      END { for (r = 1; r <= 5; r++) for (i = 1; i <= c[r]; i++) print out[r, i] }'
    ;;
  goals)
    digest_goals "$facts" "$digest"
    ;;
  no-question)
    # A reader re-read the issue in full and found no open question: remember it until the issue changes.
    case "${2:-}" in ''|*[!0-9]*) echo "Usage: sh digest.sh no-question NUMBER" >&2; exit 2 ;; esac
    [ -n "$facts" ] || { echo "No board facts yet; run read.sh first." >&2; exit 1; }
    mkdir -p "$dir"
    printf '%s\n' "$(digest_no_question "$facts" "$digest" "$2")" > "$dir/digest.tsv.new" && mv "$dir/digest.tsv.new" "$dir/digest.tsv"
    echo "Noted: #$2 has no open question; it is not proposed for mark-waiting again until it changes."
    ;;
  *)
    echo "Usage: sh digest.sh save | show | goals | no-question NUMBER" >&2; exit 2 ;;
esac
