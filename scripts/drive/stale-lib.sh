#!/bin/sh
# The drive does not take In progress on faith. An issue is In progress only
# while an agent is on it; one that nobody works would otherwise stop the
# drive for hours, because it reads In progress as "a round is running". The
# plan judges each In progress issue, says so on a `stale` line, and sets it
# right before it judges whether the round has landed:
#   - its pull request is held for the owner: Waiting on you, with the hold's
#     ask (one question, numbered choices, exactly one ending "Recommended.");
#   - no open pull request and nothing touched in the last two hours (no
#     comment or label on the issue, no commit on a branch named for it):
#     back to Ready.
# Sourced by plan.sh. Functions only; stale_lines, stale_say, stale_facts and
# stale_snapshot are pure, stale_apply is the one that writes (REST).

# stale_judge HAS_PULL HELD LAST_TOUCH NOW [HOURS]
# running, ready or waiting. LAST_TOUCH and NOW are epoch seconds; with no
# LAST_TOUCH the issue is left running (it is never set right on a guess).
stale_judge() {
  if [ "$2" = yes ]; then echo waiting; return 0; fi
  if [ "$1" = yes ]; then echo running; return 0; fi
  if [ -z "$3" ] || [ $(( $4 - $3 )) -lt $(( ${5:-2} * 3600 )) ]; then echo running; return 0; fi
  echo ready
}

# stale_epoch ISO: seconds since the epoch for a UTC timestamp, or nothing.
stale_epoch() {
  [ -n "$1" ] || return 0
  date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true
}

# stale_lines FACTS PULLS BRANCHES NOW [HOURS [UNITS]]
# FACTS are board-now's lines. PULLS are the open pull requests, one per line:
# NUMBER<TAB>HELD(yes|no)<TAB>CLOSES (issue numbers, comma separated)[<TAB>REFS
# (issues it only names, as "Part of #N")]. BRANCHES are "EPOCH<TAB>REF" for
# each branch's newest commit. UNITS are the started round's units, one
# "PR<TAB>ISSUES" line each (round-state-lib's started_units): the issues of
# one unit are one piece of work, so a commit on the unit's branch (named for its
# first issue), a comment on any of its issues, or its open pull request, named
# in a Part of line or as the unit's own "pr", counts for all of them, and they
# go back together or not at all. Prints one line per In progress issue that
# is not a running unit:
#   stale<TAB>ISSUE<TAB>ready|waiting<TAB>PULL<TAB>TITLE
stale_lines() {
  # Tab is whitespace to read, which collapses an empty field and shifts the
  # rest left; the unit separator is not, so an empty field stays empty.
  sl_tab=$(printf '\037')
  printf '%s\n' "$1" | tr -d '\r' | tr '\t' '\037' | while IFS="$sl_tab" read -r sl_kind sl_num sl_title sl_labels sl_updated sl_rest; do
    [ "$sl_kind" = issue ] || continue
    [ "$(state_of_labels "$sl_labels")" = in-progress ] || continue
    sl_members=$(printf '%s\n' "${6:-}" | awk -F'\t' -v n="$sl_num" '{ k = split($2, a, " "); for (i = 1; i <= k; i++) if (a[i] == n) { print $2; exit } }')
    [ -n "$sl_members" ] || sl_members=$sl_num
    sl_unitpr=$(printf '%s\n' "${6:-}" | awk -F'\t' -v n="$sl_num" '$1 != "" { k = split($2, a, " "); for (i = 1; i <= k; i++) if (a[i] == n) { print $1; exit } }')
    sl_has=no; sl_held=no; sl_pr=""; sl_touch=""
    for sl_m in $sl_members; do
      sl_pull=$(printf '%s\n' "$2" | awk -F'\t' -v n="$sl_m" '{ k = split($3, a, ","); for (i = 1; i <= k; i++) if (a[i] == n) { print $1 "\t" $2; next } k = split($4, a, ","); for (i = 1; i <= k; i++) if (a[i] == n) print $1 "\t" $2 }')
      if [ -n "$sl_pull" ]; then
        sl_has=yes
        [ -n "$sl_pr" ] || sl_pr=$(printf '%s\n' "$sl_pull" | head -n 1 | cut -f1)
        if printf '%s\n' "$sl_pull" | cut -f2 | grep -qx yes; then sl_held=yes; sl_pr=$(printf '%s\n' "$sl_pull" | awk -F'\t' '$2 == "yes" { print $1; exit }'); fi
      fi
      sl_up=$(printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v n="$sl_m" '$1 == "issue" && $2 == n { print $5; exit }')
      sl_t=$(stale_epoch "$sl_up")
      if [ -n "$sl_t" ] && { [ -z "$sl_touch" ] || [ "$sl_t" -gt "$sl_touch" ]; }; then sl_touch=$sl_t; fi
      sl_b=$(printf '%s\n' "$3" | awk -F'\t' -v n="$sl_m" '$1 + 0 > m && $2 ~ ("(^|[^0-9])" n "([^0-9]|$)") { m = $1 + 0 } END { if (m > 0) print m }')
      if [ -n "$sl_b" ] && { [ -z "$sl_touch" ] || [ "$sl_b" -gt "$sl_touch" ]; }; then sl_touch=$sl_b; fi
    done
    # The unit's own open pull request, whatever its body calls the issue.
    if [ "$sl_has" = no ] && [ -n "$sl_unitpr" ] && printf '%s\n' "$2" | cut -f1 | grep -qx "$sl_unitpr"; then sl_has=yes; sl_pr=$sl_unitpr; fi
    case "$(stale_judge "$sl_has" "$sl_held" "$sl_touch" "$4" "${5:-2}")" in
      ready) printf 'stale\t%s\tready\t\t%s\n' "$sl_num" "$sl_title" ;;
      waiting) printf 'stale\t%s\twaiting\t%s\t%s\n' "$sl_num" "$sl_pr" "$sl_title" ;;
    esac
  done
}

# stale_say STALE [HOURS]: the plan's `stale` lines, in plain words.
stale_say() {
  printf '%s\n' "$1" | awk -F'\t' -v h="${2:-2}" '
    $1 != "stale" { next }
    $3 == "waiting" { printf "stale: #%s \"%s\" was In progress, but its pull request #%s is held for you; it is moved to Waiting on you, with the question on it.\n", $2, $5, $4; next }
    { printf "stale: #%s \"%s\" was In progress with no open pull request and nothing touched in %s hours, so nobody is on it; it is back to Ready.\n", $2, $5, h }'
}

# stale_ask PULL: the comment that goes on an issue whose pull request is
# held for the owner. One question, then numbered choices; exactly one ends
# "Recommended." with its reason.
stale_ask() {
  printf 'Pull request #%s is held for you, and this issue was marked In progress, so nothing started the next work. Should it land?\n\n' "$1"
  printf '1. Read it and let it land. Recommended. It waits only for your read, and the drive can start the next work once it lands.\n'
  printf '2. Tell your agent what to change first. The issue stays here until you have said.\n'
}

# stale_labels_json LABELS NEW_SLUG: the labels of an issue, one per line, with
# every state label dropped and NEW_SLUG's added in the form the project uses.
stale_labels_json() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v slug="$2" '
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    NF && tolower($0) ~ /^state: / { spaced = 1 }
    NF && tolower($0) !~ /^state:/ && !seen[$0]++ { out = out (out == "" ? "" : ",") q($0) }
    END {
      label = "state:" slug
      if (spaced) { label = slug; gsub(/-/, " ", label); label = "state: " label }
      out = out (out == "" ? "" : ",") q(label)
      print "{\"labels\":[" out "]}"
    }'
}

# stale_apply STALE FACTS: set each stale issue right over REST. A waiting one
# gets the ask first, then the label. Prints a line for any it could not set.
stale_apply() {
  sa_tab=$(printf '\037')
  printf '%s\n' "$1" | tr '\t' '\037' | while IFS="$sa_tab" read -r sa_k sa_num sa_kind sa_pr sa_title; do
    [ "$sa_k" = stale ] || continue
    sa_labels=$(printf '%s\n' "$2" | tr -d '\r' | awk -F'\t' -v n="$sa_num" '$1 == "issue" && $2 == n { print $4; exit }' | tr ',' '\n')
    sa_slug=ready; [ "$sa_kind" = waiting ] && sa_slug=waiting-on-owner
    if [ "$sa_kind" = waiting ]; then
      gh api -X POST "repos/{owner}/{repo}/issues/$sa_num/comments" -f body="$(stale_ask "$sa_pr")" >/dev/null 2>&1 \
        || { echo "stale: could not post the question on #$sa_num; it is left In progress."; continue; }
    fi
    stale_labels_json "$sa_labels" "$sa_slug" | gh api -X PUT "repos/{owner}/{repo}/issues/$sa_num/labels" --input - >/dev/null 2>&1 \
      || echo "stale: could not change #$sa_num's State; it is read as $sa_slug for this plan only."
  done
}

# stale_facts FACTS STALE: the board facts with each stale issue's State label
# changed, so the rest of the plan reads the board as it now is.
stale_facts() {
  printf '%s\n' "$1" | awk -F'\t' -v OFS='\t' -v stale="$2" '
    BEGIN { n = split(stale, ls, "\n"); for (i = 1; i <= n; i++) { split(ls[i], f, "\t"); if (f[1] == "stale") to[f[2]] = (f[3] == "waiting" ? "waiting-on-owner" : "ready") } }
    $1 == "issue" && ($2 in to) {
      m = split($4, a, ","); out = ""
      for (j = 1; j <= m; j++) {
        l = a[j]
        if (tolower(l) ~ /^state: ?in[- ]progress$/) { l = (l ~ /: /) ? "state: " to[$2] : "state:" to[$2]; if (l ~ /: /) gsub(/-/, " ", l) }
        out = out (out == "" ? "" : ",") l
      }
      $4 = out
    }
    { print }'
}

# stale_snapshot SNAPSHOT STALE: the plan's snapshot with each stale issue's state changed.
stale_snapshot() {
  printf '%s\n' "$1" | awk -F'\t' -v OFS='\t' -v stale="$2" '
    BEGIN { n = split(stale, ls, "\n"); for (i = 1; i <= n; i++) { split(ls[i], f, "\t"); if (f[1] == "stale") to[f[2]] = (f[3] == "waiting" ? "waiting-on-owner" : "ready") } }
    $1 == "issue" && ($2 in to) && $4 == "in-progress" { $4 = to[$2] }
    { print }'
}

# carried_holds FACTS PULLS: a Ready issue that an open pull request already
# closes is never started again (a second agent would do work the pull request
# carries), whether the pull request is held for the owner or a member of the
# queue's running batch. One hold line per such issue, in the shape of
# bundle-lib's hold_reasons: hold<TAB>NUMBER<TAB>TITLE<TAB>WHY. PULLS are
# NUMBER<TAB>HELD<TAB>CLOSES, as stale_lines reads them.
carried_holds() {
  ch_us=$(printf '\037')
  printf '%s\n' "$1" | tr -d '\r' | tr '\t' '\037' | while IFS="$ch_us" read -r ch_kind ch_num ch_title ch_labels ch_rest; do
    [ "$ch_kind" = issue ] || continue
    [ "$(state_of_labels "$ch_labels")" = ready ] || continue
    # A held pull request that only refers to the issue (Refs #N, a spec draft) is the issue's real ask, so it holds it as a closing one does.
    ch_pull=$(printf '%s\n' "$2" | awk -F'\t' -v n="$ch_num" '{ k = split($3, a, ","); for (i = 1; i <= k; i++) if (a[i] == n) { print $1 "\t" $2; exit } if ($2 == "yes") { k = split($4, a, ","); for (i = 1; i <= k; i++) if (a[i] == n) { print $1 "\t" $2; exit } } }')
    [ -n "$ch_pull" ] || continue
    ch_pr=$(printf '%s' "$ch_pull" | cut -f1); ch_held=$(printf '%s' "$ch_pull" | cut -f2)
    if [ "$ch_held" = yes ]; then ch_why="Its pull request (#$ch_pr) is held for your read; no agent is started on it"
    else ch_why="Its pull request (#$ch_pr) is already open and carries it; no agent is started on it"; fi
    printf 'hold\t%s\t%s\t%s\n' "$ch_num" "$ch_title" "$ch_why"
  done
}

# pull_link_row LIST_LINE: the open pull request the plan reads from REST as one
# line of five fields separated by the unit separator (number, branch, labels,
# its "Queue: hold" line, the issue numbers it closes), as
# NUMBER<TAB>HELD<TAB>CLOSES. The separator is not whitespace to read, so a
# pull request with no hold line or no labels keeps its empty field instead of
# having its Closes numbers shifted into it (the drive once called the issues
# of two open pull requests stale for that).
pull_link_row() {
  pl_us=$(printf '\037')
  printf '%s\n' "$1" | tr -d '\r' | while IFS="$pl_us" read -r pl_num pl_ref pl_labels pl_hold pl_closes pl_refs; do
    [ -n "$pl_num" ] || continue
    # A fourth field, only when the pull request names issues it refers to without closing them (Refs, Spec for).
    printf '%s\t%s\t%s' "$pl_num" "$(held_by "$pl_labels" "$pl_hold")" "$pl_closes"
    [ -n "$pl_refs" ] && printf '\t%s' "$pl_refs"
    printf '\n'
  done
}
