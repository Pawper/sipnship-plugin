#!/bin/sh
# Decisions, one file each in docs/decisions, so no pull request edits a
# shared table and no two take the same number.
#
#   sh scripts/decisions.sh new "What was decided, in a sentence or two."
#       Reserves the next number with next-number.sh (main and every open
#       pull request), writes docs/decisions/NNNN-slug.md dated today in the
#       owner's local time, and prints the path. Commit it with the change.
#   sh scripts/decisions.sh list
#       Prints the decisions as one table, in number order.
#   sh scripts/decisions.sh split [BRIEF]
#       Once: moves the decision rows of BRIEF's table (default
#       docs/product-brief.md) into one file each, replaces the table with a
#       pointer, and points the decision kind in .claude/numbering.txt at
#       the files. Review the diff and land it alone, with no other pull
#       request touching the brief open.
set -e
here=$(dirname "$0")
. "$here/decisions-lib.sh"
dir=${DECISIONS_DIR:-docs/decisions}
cmd=$1; shift 2>/dev/null || true

case "$cmd" in
  new)
    text=$*
    [ -n "$text" ] || { echo 'Usage: sh scripts/decisions.sh new "What was decided."' >&2; exit 2; }
    num=$(sh "$here/next-number.sh" decision) || exit 1
    num=$(printf '%s' "$num" | sed 's/^0*//'); [ -n "$num" ] || num=1
    mkdir -p "$dir"
    f="$dir/$(decision_name "$num" "$(decision_slug "$text")")"
    decision_file "$num" "$(date +%Y-%m-%d)" "$text" > "$f"
    echo "$f"
    ;;
  list)
    all=""
    for f in "$dir"/*.md; do [ -f "$f" ] || continue; all="$all$(cat "$f")
@@@
"; done
    decision_table "$all"
    ;;
  split)
    brief=${1:-docs/product-brief.md}
    [ -f "$brief" ] || { echo "No $brief; name the file that holds the decisions table." >&2; exit 2; }
    rows=$(decision_rows "$(cat "$brief")")
    [ -n "$rows" ] || { echo "No decision rows (| D12 | date | text |) in $brief." >&2; exit 2; }
    mkdir -p "$dir"
    made=0; kept=0
    tab=$(printf '\t')
    printf '%s\n' "$rows" | while IFS="$tab" read -r num date text; do
      [ -n "$num" ] || continue
      if ls "$dir"/"$(printf '%04d' "$num")"-*.md >/dev/null 2>&1; then continue; fi
      decision_file "$num" "$date" "$text" > "$dir/$(decision_name "$num" "$(decision_slug "$text")")"
    done
    count=$(printf '%s\n' "$rows" | grep -c .)
    dups=$(printf '%s\n' "$rows" | cut -f1 | sort | uniq -d | tr '\n' ' ')
    # Replace the table (its header, rule and rows) with a pointer.
    awk -v dir="$dir" '
      /^\|/ { if (!intable) { buf = $0 "\n"; intable = 1; hasd = 0 } else buf = buf $0 "\n"; if ($0 ~ /^\|[ \t]*D[0-9]+[ \t]*\|/) hasd = 1; next }
      intable { if (hasd && !done) { print "Decisions are one file each in `" dir "/`, numbered by `sh scripts/next-number.sh decision`. Add one with `sh scripts/decisions.sh new \"...\"`; read them all with `sh scripts/decisions.sh list`."; done = 1 } else printf "%s", buf; intable = 0 }
      { print }
      END { if (intable) { if (hasd && !done) print "Decisions are one file each in `" dir "/`, numbered by `sh scripts/next-number.sh decision`. Add one with `sh scripts/decisions.sh new \"...\"`; read them all with `sh scripts/decisions.sh list`."; else printf "%s", buf } }
    ' "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
    if [ -f .claude/numbering.txt ]; then
      awk -v d="$dir" '/^decision[ \t]/ { print "decision " d "/*.md"; done = 1; next } { print } END { if (!done) print "decision " d "/*.md" }' .claude/numbering.txt > .claude/numbering.txt.tmp && mv .claude/numbering.txt.tmp .claude/numbering.txt
    fi
    echo "Moved $count decision row(s) from $brief into $dir/, one file each; the table is now a pointer, and .claude/numbering.txt numbers decisions by file."
    [ -z "$dups" ] || echo "Rows numbered twice in the old table: $dups; the first of each became its file. Check the others by hand."
    ;;
  *)
    echo 'Usage: sh scripts/decisions.sh new "text" | list | split [BRIEF]' >&2; exit 2 ;;
esac
