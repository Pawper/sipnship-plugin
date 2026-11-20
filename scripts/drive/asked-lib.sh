#!/bin/sh
# An issue the builder asked for by name keeps its place until it is done
# (#1930). "Start this next" is a request on the drive issue, "Queue request:
# start-next #N by LOGIN". The drive answers it once, when the issue starts,
# and that answer spends the request; but an issue that lands a part and goes
# back to Ready with work left is still the one the builder asked for. So the
# plan reads the requests themselves, answered or not: every open Ready issue
# one names leads the next round, on its own or with other asked issues only,
# and says what is left. Pure; sourced by plan.sh and the plugin's tests.

# asked_issues COMMENTS
# COMMENTS are the drive issue's comments, one "at<TAB>login<TAB>body" a line,
# oldest first. The issue numbers any start-next request names, space
# separated, each once. A request is the exact form, left by the App or by the
# person it names, as work_requests reads it. Nothing when none was made.
asked_issues() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    $3 !~ /^Queue request: start-next #[0-9]+ by [A-Za-z0-9][A-Za-z0-9-]*(: .*)?$/ { next }
    {
      split($3, w, " "); n = w[4]; who = w[6]; sub(/^#/, "", n); sub(/:$/, "", who)
      if ($2 != who && $2 !~ /\[bot\]$/) next
      if (!(n in seen)) { seen[n] = 1; out = out (out == "" ? "" : " ") n }
    }
    END { if (out != "") print out }'
}

# asked_line SAY
# The plain line a kept request carries, from left_comments_say's output for
# the issue: that a part landed, what is left, and that it is still first.
# An issue nothing landed on says only that it is first.
asked_line() {
  al_tab=$(printf '\t')
  case "$1" in
    left"$al_tab"*) al_w=${1#left"$al_tab"}; al_w=${al_w%%"$al_tab"*}; printf 'A part of this landed. Left: %s. It is still first in the next round, so you do not need to ask again.\n' "$al_w" ;;
    partly) printf 'A part of this landed. What is left is being confirmed. It is still first in the next round, so you do not need to ask again.\n' ;;
    *) printf 'You asked for this one, so it is first in the next round.\n' ;;
  esac
}

# asked_ready ASKED READY
# ASKED is asked_issues' output, READY the numbers of the Ready issues the
# plan is placing (space separated): the asked ones among them, in READY's order.
asked_ready() {
  printf '%s\n' "$2" | tr ' ' '\n' | awk -v a=" $1 " 'NF && index(a, " " $1 " ") { out = out (out == "" ? "" : " ") $1 } END { if (out != "") print out }'
}
