# attention_recheck LIST
# Re-read each pull request the drain listed before calling it a failure:
# one red earlier may be green, or only cancelled, by now, and one that
# merged or closed during the drain is not a failure at all. Prints the
# rows still needing attention, "NUMBER<TAB>why".
attention_recheck() {
  rm -f "$flaky_dir/pr-"*.tsv 2>/dev/null
  printf '%s\n' "$1" | while IFS="$tab" read -r a_num a_why; do
    [ -n "$a_num" ] || continue
    # A pull request that merged or closed during this drain is not a failure.
    a_state=$(gh api "repos/{owner}/{repo}/pulls/$a_num" --jq .state 2>/dev/null | tr -d '\r')
    if [ -n "$a_state" ] && [ "$a_state" != open ]; then say "  #$a_num is $a_state now; not a failure." >&2; continue; fi
    case "$a_why" in
      *"failed CI twice"*)
        now=$(pr_rollup "$(pr_field "$a_num" 2)")
        if [ "$now" = red ]; then printf '%s\t%s\n' "$a_num" "$a_why"
        else say "  #$a_num was red earlier in this drain and is $now now; not a failure." >&2; fi ;;
      *) printf '%s\t%s\n' "$a_num" "$a_why" ;;
    esac
  done
}

# attention_report LIST [ERRORS]
# Print the findings, "NUMBER<TAB>why" a row, and return the drain's exit
# code. A red, conflicting or left-out pull request needs its owner, not
# the queue: the drain did its work, so findings alone return 0. Only the
# queue's own failure (ERRORS, one line saying what broke) returns 1.
attention_report() {
  if [ -n "$1" ]; then
    say "Needs attention:"
    printf '%s\n' "$1" | while IFS="$tab" read -r a_num a_why; do
      [ -n "$a_num" ] || continue
      say "  #$a_num $a_why"
      case "$a_why" in *"failed CI twice"*) why_red "$a_num" | tee -a "$log_file" ;; esac
    done
  fi
  [ -z "$2" ] || { say "The queue itself failed: $2"; return 1; }
  return 0
}
