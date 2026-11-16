#!/bin/sh
# A red batch finds its member by halving. Sourced by scripts/ci/merge-queue.sh;
# functions only. The pure rules (batch_halves, halving_next, halving_say) are
# in rules-batch.sh; this is the part that calls git and gh.
#
# The batch's full run went red. Its pull request is closed (the caller did
# that); here the members are split in two and each half is run as a batch of
# its own, by the same script, so a red half halves itself in turn. A half
# that is one pull request goes through the serial queue as a batch of one
# does. When the first half lands green and the second is one pull request,
# that one is the culprit without another run: it is named with the failing
# test and goes through the serial queue.

# batch_failed_test BRANCH: the first failing test of the batch's latest run,
# read from its log, or nothing.
batch_failed_test() {
  bft_run=$(latest_run "$1"); bft_id=${bft_run%%	*}
  [ -n "$bft_id" ] || return 0
  failed_tests_from_log "$(gh run view "$bft_id" --log-failed 2>/dev/null)" | head -n 1
}

# batch_suspect PR: the failure points at this change, so it waits for a new
# push. Its head commit goes in $flaky_dir/suspects.tsv; the drain leaves out
# a change whose head is still that commit (drop_suspects), so the same
# change is not tried again, together with the others, for the same failure.
batch_suspect() {
  bs_sha=$(gh api "repos/{owner}/{repo}/pulls/$1" --jq .head.sha 2>/dev/null | tr -d '\r')
  [ -n "$bs_sha" ] || return 0
  printf '%s\t%s\n' "$1" "$bs_sha" >> "$flaky_dir/suspects.tsv" 2>/dev/null || true
}

# batch_half_run MEMBERS: one half, as a batch of its own inside this queue's
# lock; its exit status is the batch's (zero when it landed).
batch_half_run() {
  QUEUE_IN_DRAIN=1 QUEUE_HALVING=yes sh "$0" --batch --base "$base" $1
}

# main_red_issue: the number of the open issue labeled ci-red, or nothing. A
# batch that goes red while main is already red is red for main's reasons: no
# member is blamed and none is landed on its pull request checks, which do not
# run the tests.
main_red_issue() {
  gh api "repos/{owner}/{repo}/issues?labels=ci-red&state=open&per_page=1" --jq '.[0].number // ""' 2>/dev/null | tr -d '\r'
}

# batch_red BRANCH CARRIED DROPPED: the batch's run is not green. With two or
# more members, halve; with one, say so. Always ends the queue run (exit).
# A member the failure points at is never landed here: it waits for a new
# push, and a half that is one pull request gets its own full run (batch.sh).
batch_red() {
  br_dropped=$3
  br_members=$(printf '%s' "$2" | cut -f1 | sed '/^$/d' | tr '\n' ' ')
  br_n=$(printf '%s\n' $br_members | grep -c .)
  br_test=$(batch_failed_test "$1")
  [ -z "$br_test" ] || echo "The batch's full run failed at: $br_test"
  br_main=$(main_red_issue)
  if [ -n "$br_main" ]; then
    echo "Main is already red (issue #$br_main), so this batch is red for main's reasons and no member is blamed. Nothing merged; repair main first, and the members are tried again after."
    exit 1
  fi
  if [ "$br_n" -lt 2 ] || [ -n "${QUEUE_NO_HALVING:-}" ]; then
    echo "The batch run is not green; nothing merged. Fix it on $1 or drop a PR and run again."
    [ "$br_n" -ne 1 ] || batch_suspect "$br_members"
    exit 1
  fi
  set -- $br_members
  br_h=$(batch_halves "$@")
  br_a=$(printf '%s\n' "$br_h" | sed -n 1p); br_b=$(printf '%s\n' "$br_h" | sed -n 2p)
  echo "The batch run is not green. Finding the member by halving: running #$(printf '%s' "$br_a" | sed 's/ / #/g') first; #$(printf '%s' "$br_b" | sed 's/ / #/g') after it."
  br_rc=0; batch_half_run "$br_a" || br_rc=$?
  br_single=yes; case "$br_b" in *" "*) br_single=no ;; esac
  if [ "$br_rc" -eq 0 ] && [ "$br_single" = yes ]; then
    # The first half is green and the other is one pull request: it is the one.
    gh_write api -X POST "repos/{owner}/{repo}/issues/$br_b/comments" -f body="$(halving_say "$br_b" "$br_test")" >/dev/null 2>&1 || true
    batch_suspect "$br_b"
    batch_line "$br_b" "dropped" "the batch went red with it and green without it${br_test:+ ($br_test)}"
    batch_line "$br_b" "waits for a new push" "it is not landed on its pull request checks alone; they do not run the tests"
  else
    batch_half_run "$br_b" || br_rc=$?
  fi
  for pr in $br_dropped; do serial_one "$pr"; done
  if [ -z "$QUEUE_IN_DRAIN" ]; then deploy_if_due "$b_begin"; fi
  exit 0
}
