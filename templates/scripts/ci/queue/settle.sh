#!/bin/sh
# The queue leaves no issue In progress behind. An issue is In progress only
# while an agent is on it, and the drive reads In progress as "a round is
# running", so one left behind stops it for hours. Sourced by
# scripts/ci/merge-queue.sh; functions only.
#
#   settle_merged PR   after PR merged: an issue it names that is still open and
#                      In progress returns to Ready (a pull request that merges
#                      without a Closes line, or one GitHub did not close).
#   settle_held PR     PR is held for the owner (pr_held says so): the issue it
#                      names moves from In progress to Waiting on you, with an
#                      ask: one question, numbered choices, exactly one ending
#                      "Recommended.".
#
# All REST, and quiet on any failure: the queue goes on, and the drive's own
# plan sets right whatever is left (plugin/scripts/drive/stale-lib.sh).

# settle_issues PR: the issues a pull request names, one number a line: the
# Closes / Fixes / Resolves and Part of / Refs lines of its body, and an issue-N branch name.
settle_issues() {
  si_body=$(gh api "repos/{owner}/{repo}/pulls/$1" --jq '[.head.ref, (.body // "")] | join("\n")' 2>/dev/null | tr -d '\r') || return 0
  printf '%s\n' "$si_body" | { grep -oiE '(closes|fixes|resolves|part of|refs?) #[0-9]+' | grep -oE '[0-9]+'; printf '%s\n' "$si_body" | head -n 1 | grep -oE '^issue-[0-9]+' | grep -oE '[0-9]+'; } | sort -un
}

# settle_in_progress ISSUE: yes when the issue is open and its State is In progress.
settle_in_progress() {
  sp_row=$(gh api "repos/{owner}/{repo}/issues/$1" --jq '[.state, ([.labels[].name] | join("|"))] | @tsv' 2>/dev/null | tr -d '\r') || return 0
  [ "$(printf '%s' "$sp_row" | cut -f1)" = open ] || { echo no; return 0; }
  if printf '%s' "$sp_row" | cut -f2 | tr '|' '\n' | while IFS= read -r sp_l; do state_slug "$sp_l"; done | grep -qx 'in-progress'; then echo yes; else echo no; fi
}

# settle_other_open ISSUE PR: yes when another open pull request names the issue (Closes or Part of), so work on it goes on.
settle_other_open() {
  so_open=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select(.number != '"$2"') | [.head.ref, (.body // "")] | join("\n")' 2>/dev/null | tr -d '\r') || return 0
  if printf '%s\n' "$so_open" | grep -qiE "(closes|fixes|resolves|part of|refs?) #$1([^0-9]|\$)"; then echo yes; else echo no; fi
}

# settle_set ISSUE SLUG: the issue's State, over REST (a PUT of its labels).
settle_set() {
  ss_cur=$(gh api "repos/{owner}/{repo}/issues/$1/labels" --jq '.[].name' 2>/dev/null || true)
  state_labels_json "$ss_cur" "$(state_label "$2" "$(project_label_form)")" | gh_write api -X PUT "repos/{owner}/{repo}/issues/$1/labels" --input - >/dev/null 2>&1
}

# settle_ask PR: the question left on an issue whose pull request is held.
settle_ask() {
  printf 'Pull request #%s is held for you, and this issue was marked In progress, so nothing started the next work. Should it land?\n\n' "$1"
  printf '1. Read it and let it land. Recommended. It waits only for your read, and the drive can start the next work once it lands.\n'
  printf '2. Tell your agent what to change first. The issue stays here until you have said.\n'
}

# settle_merged PR: put back any issue the merge left In progress.
settle_merged() {
  for sm_n in $(settle_issues "$1"); do
    [ "$(settle_in_progress "$sm_n")" = yes ] || continue
    # GitHub closes a named issue a moment after the merge; look once more before putting it back.
    sleep "${SETTLE_WAIT:-3}" 2>/dev/null || true
    [ "$(settle_in_progress "$sm_n")" = yes ] || continue
    [ "$(settle_other_open "$sm_n" "$1")" = yes ] && continue
    gh_write api -X POST "repos/{owner}/{repo}/issues/$sm_n/comments" -f body="Pull request #$1 merged without closing this issue, so it is back to Ready; nobody is on it now." >/dev/null 2>&1 || true
    settle_set "$sm_n" ready && say "  #$sm_n: In progress with no pull request open any more; back to Ready." || true
  done
}

# settle_held PR: move the issue of a pull request held for the owner to Waiting on you, once.
settle_held() {
  sh_seen="${flaky_dir:-${TMPDIR:-/tmp}}/settled-held"
  grep -qx "$1" "$sh_seen" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$sh_seen" 2>/dev/null || true
  for sh_n in $(settle_issues "$1"); do
    [ "$(settle_in_progress "$sh_n")" = yes ] || continue
    gh_write api -X POST "repos/{owner}/{repo}/issues/$sh_n/comments" -f body="$(settle_ask "$1")" >/dev/null 2>&1 || continue
    settle_set "$sh_n" waiting-on-owner && say "  #$sh_n: its pull request #$1 is held for you; moved to Waiting on you." || true
  done
}
