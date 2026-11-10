#!/bin/sh
# The plan's mark-waiting goals, held to the ask rule before they are proposed.
# Sourced by plan.sh after round-lib.sh (mark_waiting_ok) and the project's
# scripts/ci/ask-lib.sh (ask_verdict, ask_fix, the one reader of an ask).

# mark_waiting_goals EXTRA VERDICTS
# EXTRA is digest_goals' lines; VERDICTS is "NUMBER<TAB>WORD" per issue, the
# word ask_verdict gave its latest ask. A "mark-waiting N" line stays only for
# an ask in the shape (mark_waiting_ok), and so runs without approval; any
# other becomes an "ask-fix N" line saying what to fix, so the state-label
# hook is never the first to refuse it. Other goals pass through.
mark_waiting_goals() {
  printf '%s\n' "$1" | tr -d '\r' | while IFS= read -r mw_l; do
    case "$mw_l" in
      "mark-waiting "*)
        mw_n=$(printf '%s' "$mw_l" | sed 's/^mark-waiting \([0-9]*\).*/\1/')
        mw_t=$(printf '%s' "$mw_l" | cut -f2 | sed 's/ (a question to the owner is open)$//')
        mw_v=$(printf '%s\n' "$2" | awk -F'\t' -v n="$mw_n" '$1 == n { print $2; exit }')
        if [ "$(mark_waiting_ok "$mw_v")" = yes ]; then printf '%s\n' "$mw_l"; continue; fi
        mw_f=$(ask_fix "$mw_v")
        [ -n "$mw_f" ] || mw_f='no ask in the shape (a question, numbered choices, one "Recommended.") is on it yet; the agent that wrote the question puts it in the shape'
        printf 'ask-fix %s\t%s (not marked waiting: %s)\n' "$mw_n" "$mw_t" "$mw_f" ;;
      '') ;;
      *) printf '%s\n' "$mw_l" ;;
    esac
  done
}

# ask_verdicts_for EXTRA: "NUMBER<TAB>WORD" for each mark-waiting issue in
# EXTRA, from its comments (newest first, parted as ask_verdict reads them);
# REST, one call per such issue, and none when there are none.
ask_verdicts_for() {
  for av_n in $(printf '%s\n' "$1" | sed -n 's/^mark-waiting \([0-9]*\).*/\1/p'); do
    av_c=$(gh api "repos/{owner}/{repo}/issues/$av_n/comments?per_page=100" --jq "[.[].body] | reverse | join(\"\\n$ASK_NEXT\\n\")" 2>/dev/null | tr -d '\r')
    printf '%s\t%s\n' "$av_n" "$(printf '%s\n' "$av_c" | ask_verdict)"
  done
}
