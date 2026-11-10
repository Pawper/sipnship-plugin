#!/bin/sh
# Pure helpers for the drain's one retry of a red pull request. Loaded by
# scripts/ci/batch-lib.sh; nothing here calls git or gh.
#
# A new drain used to re-run every red pull request once more, so a rule
# check that failed on an unchanged commit was re-run by two drains and
# failed the same way both times. A re-run now needs a reason: something the
# check reads changed since the failed attempt, or the failure looks like
# infrastructure (a runner lost, a timeout, a file lock).

# body_mark TEXT: a short fingerprint of a pull request's title and body,
# the text the spec, delete, mock and private-names checks read live.
body_mark() {
  printf '%s' "$1" | cksum | cut -d ' ' -f1
}

# time_after A B: "yes" when the ISO time A is later than B, as GitHub
# writes them (2026-11-02T17:10:00Z); "no" when not or when either is empty.
time_after() {
  awk -v a="$1" -v b="$2" 'BEGIN { print (a != "" && b != "" && a > b) ? "yes" : "no" }'
}

# rule_step_failed JOBS: "yes" when a job failed on one of the "Fail when
# ..." rule checks, which read the commit and the pull request's text and
# so fail the same way again until one of them changes. JOBS is
# outside_cause's: "name<TAB>conclusion<TAB>failed step<TAB>text".
rule_step_failed() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' 'NF >= 3 && $3 ~ /^Fail when / { f = 1 } END { print f ? "yes" : "no" }'
}

# rule_failed_what JOBS: which rule check failed, in the check's own words:
# "a change grows a source file past its size limit", then its first line of
# text in brackets when the job kept one worth reading. Nothing when no rule
# check failed. JOBS as rule_step_failed reads them.
rule_failed_what() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 3 && $3 ~ /^Fail when / {
      s = $3; sub(/^Fail when /, "", s); t = $4
      if (t ~ /[Cc]ancel+ed/) t = ""
      gsub(/^[ ]+|[ ]+$/, "", t); if (length(t) > 140) t = substr(t, 1, 140)
      print s (t != "" ? " (" t ")" : ""); exit
    }'
}

# run_unfinished JOBS [SUMMARY]: "yes" when the run did not finish and no job
# failed in its own right: every job but the summary job passed, was skipped
# or was cancelled, and the summary job failed or a job was cancelled. That
# is a run that never got to say, not a failed check or a failed test.
run_unfinished() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v sum="${2:-CI passed}" '
    NF == 0 { next }
    { c = tolower($2) }
    $1 == sum { if (c == "failure" || c == "cancelled" || c == "canceled") u = 1; next }
    c == "failure" { bad = 1; next }
    ($3 != "") && (c == "cancelled" || c == "canceled") { bad = 1; next }
    c == "cancelled" || c == "canceled" { u = 1 }
    END { print (u && !bad) ? "yes" : "no" }'
}

# rerun_seen RECORDS HEAD [MARK]
# RECORDS is the drain's own record of past re-runs, "head<TAB>mark" per
# line. Print "same" when HEAD was re-run or looked at with this MARK,
# "text" when it was with another mark, and "new" when never.
rerun_seen() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v h="$2" -v m="$3" '
    $1 == h { if ($2 == m) same = 1; else other = 1 }
    END { print same ? "same" : (other ? "text" : "new") }'
}

# red_rerun JOBS RECORDS HEAD MARK PR_NEWER
# Whether the drain re-runs the failed jobs of a red pull request. JOBS as
# outside_cause reads them; PR_NEWER is "yes" when the pull request was
# edited after the failed run ended. Prints "rerun WHY" or "skip WHY":
#   infrastructure (outside_cause names one)        rerun, always, unless a
#                                                   rule check failed: that
#                                                   fails again until
#                                                   something it reads moves
#   this head and text already re-run or looked at  skip: nothing changed
#   this head's text changed since the last look    rerun
#   first look, a rule check failed                 rerun only when the
#                                                   pull request was edited
#                                                   since the run
#   first look, anything else                       rerun once, a test may
#                                                   have flaked
red_rerun() {
  rr_rule=$(rule_step_failed "$1")
  if [ "$rr_rule" = no ] && [ "$(run_unfinished "$1" "${QUEUE_SUMMARY_CHECK:-CI passed}")" = yes ]; then
    case $(rerun_seen "$2" "$3" "$4") in
      new) echo "rerun the run did not finish, so it is run once more" ;;
      *) echo "skip the run did not finish and was run once more already" ;;
    esac
    return
  fi
  rr_cause=""
  if [ "$rr_rule" = no ]; then rr_cause=$(outside_cause "$1" "${QUEUE_SUMMARY_CHECK:-CI passed}"); fi
  if [ -n "$rr_cause" ]; then echo "rerun $rr_cause"; return; fi
  case $(rerun_seen "$2" "$3" "$4") in
    same) echo "skip nothing it reads has changed since the last attempt"; return ;;
    text) echo "rerun the pull request's text changed since the last attempt"; return ;;
  esac
  if [ "$rr_rule" = yes ]; then
    if [ "$5" = yes ]; then echo "rerun the pull request was edited since the failed run"
    else echo "skip a rule check failed: $(rule_failed_what "$1"); nothing it reads has changed"; fi
    return
  fi
  echo "rerun one retry of a failure on a new commit"
}

# rerun_marks COMMENTS: the "head<TAB>mark" lines a pull request's comments
# carry from earlier drains. The record lives on the pull request, because
# a drain on a runner starts with nothing remembered.
rerun_marks() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/.*<!-- merge-queue:rerun \([0-9a-fA-F]*\) \([0-9]*\) -->.*/\1\t\2/p'
}

# rerun_note CALL HEAD MARK: the comment a drain leaves when it decides:
# what it did, why, and the hidden mark rerun_marks reads back.
rerun_note() {
  rn_what="Re-running the failed jobs of this pull request's newest run"
  case "$1" in skip\ *) rn_what="Not re-running this pull request's failed jobs" ;; esac
  printf '%s: %s.\n\n<!-- merge-queue:rerun %s %s -->\n' "$rn_what" "${1#* }" "$2" "$3"
}
