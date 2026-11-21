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
#                      closes moves from In progress to Waiting on you, with an
#                      ask naming it as a link (held_ask), left once; exactly one
#                      choice ends "Recommended.". An issue it only names is not asked.
#
# All REST, and quiet on any failure: the queue goes on, and the drive's own
# plan sets right whatever is left (plugin/scripts/drive/stale-lib.sh).

# settle_issues PR: the issues a pull request names, one number a line: the
# Closes / Fixes / Resolves and Part of / Refs lines of its body, and an issue-N branch name.
settle_issues() {
  si_body=$(gh api "repos/{owner}/{repo}/pulls/$1" --jq '[.head.ref, (.body // "")] | join("\n")' 2>/dev/null | tr -d '\r') || return 0
  printf '%s\n' "$si_body" | { grep -oiE '(closes|fixes|resolves|part of|refs?) #[0-9]+' | grep -oE '[0-9]+'; printf '%s\n' "$si_body" | head -n 1 | grep -oE '^issue-[0-9]+' | grep -oE '[0-9]+'; } | sort -un
}

# A unit whose "pr" was never recorded is found by the issues the pull request names
# (NAMED, an optional second argument), so an issue its change left out is not left
# In progress behind it (#1789).
# settle_unit_issues PR [NAMED]: the other issues of the unit whose pull request this is,
# one number a line, read from the latest started round on the drive issue (the
# open issue labeled drive; its marker lists each unit's issues and its "pr").
# A unit carries several issues in one pull request that names only some of them;
# the rest would stay In progress and hold the next round. Nothing when the
# project has no drive issue or the pull request is no unit's.
settle_unit_issues() {
  su_row=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=drive&per_page=1" --jq '.[0] | [.number, .comments] | @tsv' 2>/dev/null | tr -d '\r') || return 0
  su_n=$(printf '%s' "$su_row" | cut -f1); su_c=$(printf '%s' "$su_row" | cut -f2)
  case "$su_n" in ''|*[!0-9]*) return 0 ;; esac
  case "$su_c" in ''|*[!0-9]*) su_c=1 ;; esac
  gh api "repos/{owner}/{repo}/issues/$su_n/comments?per_page=100&page=$(( (su_c + 99) / 100 ))" --jq '.[].body' 2>/dev/null | tr -d '\r' \
    | grep -F 'sipnship-proposal {"status":"started"' | tail -n 1 | sed 's/.*sipnship-proposal {"status":"started",//; s/"held":.*//' \
    | awk -v pr="$1" -v named=" $(printf '%s' "${2:-}" | tr '\n' ' ') " '{
        n = split($0, parts, /\{"issues":/)
        for (i = 2; i <= n; i++) {
          p = parts[i]; iss = p; sub(/\].*/, "", iss); sub(/^\[/, "", iss); gsub(/ /, "", iss)
          mine = (match(p, /"pr":[0-9]+/) && substr(p, RSTART + 5, RLENGTH - 5) == pr)
          m = split(iss, a, ","); if (!mine) for (j = 1; j <= m; j++) if (a[j] != "" && index(named, " " a[j] " ")) mine = 1
          if (mine) for (j = 1; j <= m; j++) if (a[j] != "") print a[j]
        }
      }'
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

# settle_closes PR: the issues a pull request closes, one number a line (its
# Closes / Fixes / Resolves lines). A hold's ask goes on these only.
settle_closes() {
  gh api "repos/{owner}/{repo}/pulls/$1" --jq '.body // ""' 2>/dev/null | tr -d '\r' | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | sort -un
}

# settle_ask PR: the question left on the issue a held pull request closes
# (held_ask in ask-lib.sh: what is held as a link, then Approve it or Ask for changes).
settle_ask() {
  command -v held_ask >/dev/null 2>&1 || . "${here:-scripts/ci}/ask-lib.sh"
  sa_row=$(gh api "repos/{owner}/{repo}/pulls/$1" --jq '[.title, .html_url] | @tsv' 2>/dev/null | tr -d '\r')
  [ -n "$sa_row" ] || return 1
  held_ask "$1" "$(printf '%s' "$sa_row" | cut -f1)" "$(printf '%s' "$sa_row" | cut -f2)"
}

# settle_asked ISSUE PR: yes when the issue already carries the ask about PR.
settle_asked() {
  command -v held_ask_mark >/dev/null 2>&1 || . "${here:-scripts/ci}/ask-lib.sh"
  if gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --jq '.[].body' 2>/dev/null | grep -qF "$(held_ask_mark "$2")"; then echo yes; else echo no; fi
}

# settle_said_open PR ISSUE: yes when the pull request's own body names the issue on
# a line that says it stays open or was not built here, so a note already on the
# issue is still current and the generic comment would only restate it (#2246).
settle_said_open() {
  gh api "repos/{owner}/{repo}/pulls/$1" --jq '.body // ""' 2>/dev/null | tr -d '\r' \
    | grep -iE "#$2([^0-9]|\$)" | grep -qiE 'stays? open|not built|left untouched|unchanged|nothing changed' && echo yes || echo no
}

# settle_merged PR: put back any issue the merge left In progress.
settle_merged() {
  sm_named=$(settle_issues "$1")
  for sm_n in $( { printf '%s\n' "$sm_named"; settle_unit_issues "$1" "$sm_named"; } | sed '/^$/d' | sort -un); do
    [ "$(settle_in_progress "$sm_n")" = yes ] || continue
    # GitHub closes a named issue a moment after the merge; look once more before putting it back.
    sleep "${SETTLE_WAIT:-3}" 2>/dev/null || true
    [ "$(settle_in_progress "$sm_n")" = yes ] || continue
    [ "$(settle_other_open "$sm_n" "$1")" = yes ] && continue
    if [ "$(settle_said_open "$1" "$sm_n")" != yes ]; then
      gh_write api -X POST "repos/{owner}/{repo}/issues/$sm_n/comments" -f body="Pull request #$1 merged without closing this issue, so it is back to Ready; nobody is on it now." >/dev/null 2>&1 || true
    fi
    settle_set "$sm_n" ready && say "  #$sm_n: In progress with no pull request open any more; back to Ready." || true
  done
}

# settle_held PR: move the issue a pull request held for the owner closes to
# Waiting on you, with the ask, once: never an issue it only names, never twice.
settle_held() {
  sh_seen="${flaky_dir:-${TMPDIR:-/tmp}}/settled-held"
  grep -qx "$1" "$sh_seen" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$sh_seen" 2>/dev/null || true
  for sh_n in $(settle_closes "$1"); do
    [ "$(settle_in_progress "$sh_n")" = yes ] || continue
    [ "$(settle_asked "$sh_n" "$1")" = no ] || continue
    sh_ask=$(settle_ask "$1") || continue
    gh_write api -X POST "repos/{owner}/{repo}/issues/$sh_n/comments" -f body="$sh_ask" >/dev/null 2>&1 || continue
    settle_set "$sh_n" waiting-on-owner && say "  #$sh_n: its pull request #$1 is held for you; moved to Waiting on you." || true
  done
}
