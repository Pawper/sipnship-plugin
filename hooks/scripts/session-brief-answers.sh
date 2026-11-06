# Sourced by session-brief-local.sh: the brief's line for the builder's
# answers to what was asked, "1 answer since your last session". The answers
# still owed are read in the background by session-brief-slow.sh (the drive's
# answers.sh --all) into the cache; this says the ones no earlier brief has
# shown, and keeps their comment ids beside the cache, so each is named at one
# session start. Uses the hook's add, cached and sb_cache.

# answers_brief_line OWED SHOWN
# OWED is answers.sh's lines; SHOWN the comment ids an earlier brief named.
# Prints the line, or nothing when no answer is new.
answers_brief_line() {
  abl_new=$(unseen_answers "$1" "$2")
  [ -n "$abl_new" ] || return 0
  abl_n=$(printf '%s\n' "$abl_new" | grep -c '^answer #')
  abl_which=$(printf '%s\n' "$abl_new" | sed 's/^answer //; s/ (comment.*//' | head -n 3 | paste -sd';' - | sed 's/;/; /g')
  [ "$abl_n" -le 3 ] || abl_which="$abl_which; and $(( abl_n - 3 )) more"
  printf '%s %s since your last session: %s. Carry on from each: sh "%s" --all lists them.\n' "$abl_n" "$([ "$abl_n" -eq 1 ] && echo answer || echo answers)" "$abl_which" "$3"
}

# brief_answers: the line from the cache, and the ids it named kept.
brief_answers() {
  ba_script="$here/../../scripts/drive/answers.sh"
  [ -s "$sb_cache/answers" ] && [ -f "$ba_script" ] || return 0
  . "$here/../../scripts/drive/answers-lib.sh"
  ba_owed=$(cached answers)
  ba_shown=$(cat "$sb_cache/answers-shown" 2>/dev/null)
  ba_line=$(answers_brief_line "$ba_owed" "$ba_shown" "$(cd "$here/../.." && pwd)/scripts/drive/answers.sh")
  [ -n "$ba_line" ] || return 0
  add "$ba_line"
  answer_ids "$(unseen_answers "$ba_owed" "$ba_shown")" >> "$sb_cache/answers-shown" 2>/dev/null
  return 0
}
