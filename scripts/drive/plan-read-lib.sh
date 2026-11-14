#!/bin/sh
# Helpers for what the plan reads of GitHub beyond the board (specs/010-work):
# the audit issue's comment when a merged pull request only said "Part of", the
# drive issue's newest comments, and a head commit's check runs. The first two
# functions are pure (text in, text out); the others run gh over REST, as plan.sh
# does. Sourced by plan.sh after round-state-lib.sh.

# audit_stale_prs LINE
# LINE is the audit issue's latest comment, flattened to one line. When it
# says nothing but "Issues still open and labeled ready after their PR
# merged" with its "- #N (merged in #M)" entries, print each merged pull
# request's number M, one per line, unique; for any other comment (or one
# cut short) print nothing.
audit_stale_prs() {
  printf '%s\n' "$1" | awk '
    {
      s = $0
      if (index(s, "Issues still open and labeled ready after their PR merged:") != 1) exit
      sub(/^Issues still open and labeled ready after their PR merged:/, "", s)
      t = s
      while (match(t, /- #[0-9]+ \(merged in #[0-9]+\)/)) {
        e = substr(t, RSTART, RLENGTH); sub(/.*merged in #/, "", e); sub(/\)/, "", e)
        if (!(e in seen)) { seen[e] = 1; out = out e "\n" }
        t = substr(t, 1, RSTART - 1) " " substr(t, RSTART + RLENGTH)
      }
      gsub(/[ \t]+/, "", t)
      if (t == "") printf "%s", out
    }'
}

# audit_only_part_of LINE BODIES
# BODIES are the merged pull requests audit_stale_prs named, one
# "NUMBER<TAB>BODY" a line (the body on one line). "yes" when LINE is only
# the stale section and none of its pull requests closes the issue it is
# listed for with a Closes, Fixes or Resolves line: each said "Part of", so
# the issue stays open on purpose and the audit's line is no goal. Else "no".
audit_only_part_of() {
  printf '%s\n' "$2" | awk -F'\t' -v line="$1" '
    BEGIN { n = split(line, ws, /- #/) }
    { body[$1] = tolower($2) }
    END {
      if (n < 2) { print "no"; exit }
      for (i = 2; i <= n; i++) {
        iss = ws[i]; sub(/[^0-9].*/, "", iss)
        pr = ws[i]; if (!match(pr, /merged in #[0-9]+/)) { print "no"; exit }
        pr = substr(pr, RSTART + 11, RLENGTH - 11)
        if (!(pr in body)) { print "no"; exit }
        b = body[pr]
        while (match(b, /(close[sd]?|fix(e[sd])?|resolve[sd]?):? #[0-9]+/)) {
          c = substr(b, RSTART, RLENGTH); sub(/.*#/, "", c)
          if (c == iss) { print "no"; exit }
          b = substr(b, RSTART + RLENGTH)
        }
      }
      print "yes"
    }'
}

# audit_unless_part_of LINE
# LINE is the audit issue's latest comment, flattened. An issue a merged pull
# request left open with "Part of" is open on purpose, so a comment of only
# those entries is no goal: prints nothing then (one REST call per merged
# pull request named, for its body), and LINE unchanged otherwise.
audit_unless_part_of() {
  aup_prs=$(audit_stale_prs "$1")
  if [ -z "$aup_prs" ]; then printf '%s\n' "$1"; return 0; fi
  aup_bodies=""
  for aup_p in $aup_prs; do
    aup_bodies="${aup_bodies}${aup_p}$(printf '\t')$(gh api "repos/{owner}/{repo}/pulls/$aup_p" --jq '(.body // "") | gsub("[\r\n\t]+"; " ")' 2>/dev/null | tr -d '\r')
"
  done
  [ "$(audit_only_part_of "$1" "$aup_bodies")" = yes ] || printf '%s\n' "$1"
}

# read_drive_comments DRIVE_LINE
# The drive issue's newest comments, one "at<TAB>login<TAB>body" a line (the
# last two pages of 100), from the one-line issue read of AUTO_DRIVE_QUERY.
read_drive_comments() {
  rdc_n=$(printf '%s\n' "$1" | head -n 1 | cut -f1)
  case "$rdc_n" in ""|*[!0-9]*) return 0 ;; esac
  rdc_all=""
  for rdc_page in $(comment_pages "$(printf '%s\n' "$1" | head -n 1 | cut -f3)"); do
    rdc_all="${rdc_all}$(gh api "repos/{owner}/{repo}/issues/$rdc_n/comments?per_page=100&page=$rdc_page" --jq '.[] | [.created_at, .user.login, (.body | gsub("\t"; " ") | gsub("\r"; ""))] | @tsv' 2>/dev/null)
"
  done
  without_bare_path_comments "$rdc_all" | sed '/^$/d'  # a body that is only a file name is no comment
}

# run_failed_checks RUNS_JQ_LINES
# RUNS are "ID<TAB>SHA<TAB>EPOCH" lines of workflow runs. Prints "SHA<TAB>EPOCH<TAB>CHECK"
# for each job of those runs that failed (one REST call per run).
run_failed_checks() {
  printf '%s\n' "$1" | tr -d '\r' | while IFS="$(printf '\t')" read -r rfc_id rfc_sha rfc_at; do
    [ -n "$rfc_id" ] || continue
    gh api "repos/{owner}/{repo}/actions/runs/$rfc_id/jobs?per_page=100" --jq ".jobs[] | select(.conclusion == \"failure\") | [\"$rfc_sha\", \"$rfc_at\", .name] | @tsv" 2>/dev/null | tr -d '\r'
  done
}

# main_finished_checks
# Main's newest finished jobs, "EPOCH<TAB>CHECK<TAB>CONCLUSION" (twelve runs, one REST call each).
main_finished_checks() {
  gh api "repos/{owner}/{repo}/actions/runs?branch=main&event=push&status=completed&per_page=12" --jq '.workflow_runs[] | [(.id | tostring), (.created_at | fromdateiso8601 | tostring)] | @tsv' 2>/dev/null | tr -d '\r' \
    | while IFS="$(printf '\t')" read -r mfc_id mfc_at; do
      [ -n "$mfc_id" ] || continue
      gh api "repos/{owner}/{repo}/actions/runs/$mfc_id/jobs?per_page=100" --jq ".jobs[] | select(.conclusion == \"failure\" or .conclusion == \"success\") | [\"$mfc_at\", .name, .conclusion] | @tsv" 2>/dev/null | tr -d '\r'
    done
}

# head_checks_pending SHA
# "yes" when the head commit's check runs are not all completed (one REST call).
head_checks_pending() {
  checks_pending "$(gh api "repos/{owner}/{repo}/commits/$1/check-runs?per_page=100" --jq '.check_runs[] | [.status, (.conclusion // "")] | @tsv' 2>/dev/null)"
}

# open_batch_pr
# The number of an open pull request carrying the queue batch marker: a batch already landing its members, so the queue is
# running whatever its log says. Nothing when none is open or the project has no queue (one REST call).
open_batch_pr() {
  [ -f scripts/ci/merge-queue.sh ] || return 0
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '[.[] | select((.body // "") | (contains("<!-- merge-queue:batch -->") or startswith("One integration run for the pull requests below"))) | .number][0] // empty' 2>/dev/null | tr -d '\r'
}

# audit_last_line FACTS
# The audit issue's latest comment as the plan's `audit<TAB>TEXT` line (one gh call), or
# nothing when there is none or it only says "Part of".
audit_last_line() {
  al_issue=$(printf '%s\n' "$1" | awk -F'\t' '$1 == "issue" && ("," $4 ",") ~ /,audit,/ { print $2; exit }')
  [ -n "$al_issue" ] || return 0
  al_last=$(gh issue view "$al_issue" --json comments --jq '.comments[-1].body // ""' 2>/dev/null | tr '\n' ' ' | cut -c1-200)
  [ -n "$al_last" ] || return 0
  al_last=$(audit_unless_part_of "$al_last")
  [ -z "$al_last" ] || printf 'audit\t%s\n' "$al_last"
}

# plan_say TEXT
# One progress line on stderr as the plan reads, so a tick that watches the clock can tell a
# slow plan from a hung one: the proposal itself is printed only at the end, on stdout.
plan_say() { printf 'plan: %s\n' "$1" >&2; }
