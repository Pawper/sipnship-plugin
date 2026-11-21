#!/bin/sh
# What is left of an issue, when an agent that built only part said so (#1623).
# One change closes its issue and a leftover is a new issue, so nothing here
# reads an issue as partly landed. A note in the fixed form, on a line of its
# own in a comment, sizes and places the issue from what it names:
#     Left: <what is still to build> | areas: <area names>
# The newest note wins. Pure; sourced by plan.sh and the plugin tests.

# left_comments_say COMMENTS
# COMMENTS is one comment per line, oldest first, a line end inside a comment
# written as the two characters "\n" (gh's --jq does this). Prints
#   left<TAB>WORDS<TAB>AREAS   when the newest note is in the fixed form,
# and nothing otherwise: an issue is closed by the change that lands it, and what a
# change leaves undone is a new issue, so no issue is read as partly landed.
left_comments_say() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NF == 0 { next }
    {
      n = split($0, ln, /\\n/)
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
    }'
}

# left_title TITLE SAY
# The title a proposal line shows. A note says what is left, in its words; any
# other issue keeps its title.
left_title() {
  lt_tab=$(printf '\t')
  case "$2" in
    left"$lt_tab"*) lt_w=${2#left"$lt_tab"}; lt_w=${lt_w%%"$lt_tab"*}; printf '%s (left: %s)\n' "$1" "$lt_w" ;;
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

# answer_leads COMMENTS
# COMMENTS is one comment a line, oldest first, a line end inside a comment
# written as "\n" (left_comments_say's own shape). "yes" when the newest
# comment is a "Builder answer:" line, the fixed form the service and the
# dashboard both write (specs/022-asks): the issue just left Needs you by an
# answer, with no question left open on it, so it leads the next round by
# itself, with no second press (#2079); "no" otherwise, including an issue
# no comment ever answered.
answer_leads() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    NF == 0 { next }
    {
      n = split($0, ln, /\\n/); said = 0
      for (i = 1; i <= n; i++) if (ln[i] ~ /^[ \t>*_]*Builder answer:[ *_]* #[0-9]+ choice [0-9]/) said = 1
      last = said
    }
    END { print (last ? "yes" : "no") }'
}

# answer_lead_apply NUM ASKED
# Called from plan.sh's loop of ready issues, right after plan_ready_guess has
# set ready_answer_led for NUM: when it is yes, and NUM is not already one of
# ASKED's issues (asked_issues' output; an asked issue leads for that reason,
# never said twice), adds NUM to answer_led (the numbers rush_first gives the
# next round, space separated) and a plain line to answer_led_notes, both the
# caller's own globals, set to "" before the loop (#2079). A function, not a
# subshell, so it can grow them; nothing when NUM does not lead this way.
answer_lead_apply() {
  [ "$ready_answer_led" = yes ] || return 0
  case " $2 " in *" $1 "*) return 0 ;; esac
  answer_led="${answer_led} $1"
  answer_led_notes="${answer_led_notes}answered: $1 You answered this one, so it is first in the next round.
"
}

# plan_ready_guess
# For the ready issue plan.sh is reading (num, title, c, mocks_text, areas_text,
# past, left_reads): sets g to the files it touches and title to its title,
# planned from what is left when a merged pull request worked on it, else from
# its whole body; sets ready_answer_led (answer_leads) from the same comments,
# so an issue the owner just answered leads the next round without a second
# read. At most PLAN_LEFT_READS reads a plan (12), so the plan stays quick.
plan_ready_guess() {
  left_say=""; ready_answer_led=no
  # The reads share one time budget (plan_left_until, a count of SECONDS set by plan.sh): a slow GitHub never holds the plan on the issues' comments, and an issue not read is planned from its whole body (#1926).
  if [ "$left_reads" -lt "${PLAN_LEFT_READS:-12}" ] && [ "${SECONDS:-0}" -lt "${plan_left_until:-999999}" ]; then
    left_reads=$((left_reads + 1))
    prg_comments=$(gh api "repos/{owner}/{repo}/issues/$num/comments?per_page=100" --jq '.[] | .body | gsub("\r"; "") | gsub("\n"; "\\n")' 2>/dev/null)
    left_say=$(left_comments_say "$prg_comments")
    ready_answer_led=$(answer_leads "$prg_comments")
  fi
  g=""
  case "$left_say" in
    left*) g=$(left_areas_files "$left_say" "$areas_text"); [ -n "$g" ] || g=$(guess_files "$(left_title "$title" "$left_say")" "$mocks_text" "$past") ;;
    *) g=$(guess_files "$title $c" "$mocks_text" "$past"); [ -n "$g" ] || g=$(title_area_files "$title $c" "$areas_text") ;;
  esac
  title=$(left_title "$title" "$left_say")
}
