#!/bin/sh
# What is left of an issue a merged pull request worked on but did not close
# (#1623). An issue returns to Ready looking whole; the plan must not size and
# place it from its whole body. Two things on the issue say what is true now:
#
#   a note in the fixed form, on a line of its own in a comment:
#     Left: <what is still to build> | areas: <area names>
#   the settle step's comment "Pull request #N merged without closing this
#     issue, so it is back to Ready", which says part of it landed.
#
# The newest of the two wins. A note after the settle comment says what is
# left; the settle comment with no note after it means "partly landed, nobody
# has said what is left". Pure; sourced by plan.sh and the plugin's tests.

# left_comments_say COMMENTS
# COMMENTS is one comment per line, oldest first, a line end inside a comment
# written as the two characters "\n" (gh's --jq does this). Prints
#   left<TAB>WORDS<TAB>AREAS   when the newest note is in the fixed form,
#   partly                     when part landed and no note says what is left,
# and nothing for an issue no merged pull request worked on.
left_comments_say() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NF == 0 { next }
    {
      n = split($0, ln, /\\n/)
      if (index($0, "merged without closing this issue")) { state = "partly"; words = ""; areas = "" }
      for (i = 1; i <= n; i++) {
        if (ln[i] ~ /^[ \t]*Left:[ \t]*[^|]+(\|[ \t]*areas:.*)?$/) {
          l = ln[i]; sub(/^[ \t]*Left:[ \t]*/, "", l)
          w = l; a = ""
          p = index(l, "|")
          if (p) { w = substr(l, 1, p - 1); a = substr(l, p + 1); sub(/^[ \t]*areas:[ \t]*/, "", a) }
          words = trim(w); areas = trim(a); state = "left"
        }
      }
    }
    END {
      if (state == "left" && words != "") printf "left\t%s\t%s\n", words, areas
      else if (state == "partly") print "partly"
    }'
}

# left_title TITLE SAY
# The title a proposal line shows. A note says what is left, in its words; a
# partly landed issue says so (the drive's own reader then writes the note,
# left-reader-lib.sh); any other issue keeps its title.
left_title() {
  lt_tab=$(printf '\t')
  case "$2" in
    left"$lt_tab"*) lt_w=${2#left"$lt_tab"}; lt_w=${lt_w%%"$lt_tab"*}; printf '%s (left: %s)\n' "$1" "$lt_w" ;;
    partly) printf '%s (partly landed)\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# left_areas_files SAY AREAS_TEXT
# The first path of each area a note names (comma or space separated names),
# comma separated, from the areas file; nothing when the note names none or
# the file has no such area.
left_areas_files() {
  la_tab=$(printf '\t')
  case "$1" in left"$la_tab"*) ;; *) return 0 ;; esac
  la_a=${1#left"$la_tab"*"$la_tab"}; [ -n "$la_a" ] || return 0
  la_a=$(printf '%s' "$la_a" | tr 'A-Z,' 'a-z ' | tr -s ' ')
  printf '%s\n' "$2" | tr -d '\r' | awk -v want=" $la_a " '
    /^#/ || NF < 2 { next }
    { if (index(want, " " tolower($1) " ")) out = out (out == "" ? "" : ",") $2 }
    END { print out }'
}

# plan_ready_guess
# For the ready issue plan.sh is reading (num, title, c, mocks_text, areas_text,
# past, left_reads): sets g to the files it touches and title to its title,
# planned from what is left when a merged pull request worked on it, else from
# its whole body. At most PLAN_LEFT_READS reads a plan (12), so the plan stays quick.
plan_ready_guess() {
  left_say=""
  # The reads share one time budget (plan_left_until, a count of SECONDS set by plan.sh): a slow GitHub never holds the plan on the issues' comments, and an issue not read is planned from its whole body (#1926).
  if [ "$left_reads" -lt "${PLAN_LEFT_READS:-12}" ] && [ "${SECONDS:-0}" -lt "${plan_left_until:-999999}" ]; then
    left_reads=$((left_reads + 1))
    left_say=$(left_comments_say "$(gh api "repos/{owner}/{repo}/issues/$num/comments?per_page=100" --jq '.[] | .body | gsub("\r"; "") | gsub("\n"; "\\n")' 2>/dev/null)")
  fi
  g=""
  case "$left_say" in
    left*) g=$(left_areas_files "$left_say" "$areas_text"); [ -n "$g" ] || g=$(guess_files "$(left_title "$title" "$left_say")" "$mocks_text" "$past") ;;
    *) g=$(guess_files "$title $c" "$mocks_text" "$past"); [ -n "$g" ] || g=$(title_area_files "$title $c" "$areas_text") ;;
  esac
  title=$(left_title "$title" "$left_say")
}
