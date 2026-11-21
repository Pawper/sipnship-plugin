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
    rdc_all="${rdc_all}$(gh api "repos/{owner}/{repo}/issues/$rdc_n/comments?per_page=100&page=$rdc_page" --jq '.[] | .created_at + "\t" + .user.login + "\t" + (.body | gsub("\t"; " ") | gsub("\r"; "") | gsub("\n"; "\\n"))' 2>/dev/null)  # not @tsv, which doubles every backslash and cut a reason at its quote (#2104); a newline stays the two characters \n as @tsv wrote it
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
  checks_pending "$(head_check_lines "$1")"  # board-checks-lib.sh
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
# plan_stage NAME: where the plan is, with the seconds it has run, on its error stream, so a run that stops answering shows the stage it stopped in (#1794).
plan_stage() {
  printf 'plan: stage %s, %ss in\n' "$1" "${SECONDS:-0}" >&2
  # A plan that has run past its bound ends itself, naming the stage, instead of being killed from outside: a plan stopped by hand left its shells running and still starting new ones (#1794).
  if [ "${SECONDS:-0}" -gt "${PLAN_MAX_SECONDS:-900}" ] 2>/dev/null; then
    printf 'plan: stopped after stage %s: %ss is past the %ss bound (PLAN_MAX_SECONDS)\n' "$1" "${SECONDS:-0}" "${PLAN_MAX_SECONDS:-900}" >&2
    echo "stop: the plan ran past its time bound (${SECONDS}s, after the stage \"$1\"); nothing is proposed from a partial read"
    exit 0
  fi
}

# queue_state_of GLOB: none without a queue log, else stale or recent by the newest log's age and last line.
queue_state_of() {
  qs_state=none
  if [ -n "$1" ]; then
    qs_newest=""; qs_m=0
    for qs_f in $1; do
      [ -f "$qs_f" ] || continue
      qs_t=$(stat -c %Y "$qs_f" 2>/dev/null || stat -f %m "$qs_f" 2>/dev/null || echo 0)
      if [ "$qs_t" -gt "$qs_m" ]; then qs_m=$qs_t; qs_newest=$qs_f; fi
    done
    if [ -n "$qs_newest" ]; then
      if [ "$(queue_is_stale "$qs_m" "$(date +%s)" "$(tail -n 1 "$qs_newest")")" = yes ]; then qs_state=stale; else qs_state=recent; fi
    fi
  fi
  printf '%s\n' "$qs_state"
}

# snapshot_rows FACTS RULES OWNER_PHRASES
# Turn the board facts into the snapshot's rows (pr, red and issue lines), with no further network calls.
snapshot_rows() {
  sr_rules=$2; sr_owner=$3; sr_us=$(printf '\037')
  printf '%s\n' "$1" | tr '\t' '\037' | while IFS="$sr_us" read -r kind num title a b c d e; do
    case "$kind" in
      pr)
        case "$a" in SUCCESS) ci=green ;; FAILURE|ERROR) ci=red ;; *) ci=pending ;; esac
        merge=$(printf '%s' "$b" | tr 'A-Z' 'a-z')
        class=app
        if [ -n "$sr_rules" ]; then
          cls=$(sh -c '. scripts/ci/lib.sh; classify_paths "$1" "$2"' sh "$(printf '%s' "$d" | tr ',' '\n')" "$sr_rules")
          case " $cls " in *" app "*|*" other "*|*" tests "*|*" data "*) class=app ;; *) class=other ;; esac
        fi
        printf 'pr\t%s\t%s\t%s\t%s\t%s\n' "$num" "$title" "$ci" "$merge" "$class"
        ;;
      issue)
        if command -v labels_facts >/dev/null 2>&1; then labels_facts "$a"
        else lf_standing=$(standing_issue "$a"); case ",$a," in *",ci-red,"*) lf_red=yes ;; *) lf_red=no ;; esac; lf_state=$(state_of_labels "$a"); fi
        state=$lf_state
        # A red main's issue is the fix-main goal alone: it is never also a ready issue to dispatch (#1879).
        [ "$lf_red" = no ] || { printf 'red\t%s\n' "$num"; [ "$state" != ready ] || continue; }
        [ "$lf_standing" = yes ] && [ "$state" = ready ] && continue  # the drive and audit issues are never dispatched
        case "$state" in
          ready)
            # Title and the start of the body, both from the one call; an owner-decision match is a candidate with its sentence.
            printf 'issue\t%s\t%s\tready\t%s\n' "$num" "$title" "$(owner_issue_fields "$num" "$title" "$c" "$sr_owner")" ;;
          in-progress|waiting-on-owner|blocked)
            printf 'issue\t%s\t%s\t%s\tno\n' "$num" "$title" "$state" ;;
        esac
        ;;
    esac
  done
}
