#!/bin/sh
# Serial mode: one pull request at a time. Sourced by
# scripts/ci/merge-queue.sh; functions only.

# sync_worktree BRANCH: never move a branch from outside its worktree. When
# the queue advances a branch on the remote, bring the worktree's files
# along, so the folder does not look full of edits it never made.
sync_worktree() {
  sw_path=$(worktree_of "$1")
  [ -n "$sw_path" ] || return 0
  git -C "$sw_path" pull -q --ff-only >/dev/null 2>&1 || echo "note: the worktree at $sw_path could not fast-forward; update it by hand before working there"
}

serial_one() {
  pr=$1
  # Held: not merged, unless a person ran --serial with a reason.
  hw=$(pr_held "$pr")
  if [ -n "$hw" ] && { [ -n "$QUEUE_IN_DRAIN" ] || [ -z "$because" ]; }; then batch_line "$pr" "not merged" "$hw; remove the hold, or merge it with --serial $pr --because \"why\""; return 0; fi
  why=$(folder_blocks "$pr"); [ -n "$why" ] || why=$(migration_blocks "$pr")
  if [ -n "$why" ]; then batch_line "$pr" "refused" "$why"; return 0; fi
  if ! fetch_base "pull/$pr/head"; then
    batch_line "$pr" "not merged" "could not fetch $base; it is tried again next round"
    printf '%s\n' "$pr" >> "$flaky_dir/untried" 2>/dev/null || true
    return 0
  fi
  head=$(pr_field "$pr" 2)
  hb=$(pr_field "$pr" 1)
  merge_base=$(git merge-base "origin/$base" "$head")
  pr_classes=$(classify_paths "$(git diff --name-only "$merge_base" "$head")" "$rules")
  main_classes=$(classify_paths "$(git diff --name-only "$merge_base" "origin/$base")" "$rules")
  # A conflict with main is said as one, with its files, instead of
  # "updated" round after round while nothing can merge.
  if [ "$(mergeable_word "$(pr_field "$pr" 5)")" = CONFLICTING ] || ! git merge-tree --write-tree origin/"$base" "$head" >/dev/null 2>&1; then
    files=$(git merge-tree --write-tree --name-only origin/"$base" "$head" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    if [ "$(mergeable_word "$(pr_field "$pr" 5)")" = CONFLICTING ] || [ -n "$files" ]; then
      batch_line "$pr" "not merged" "$(conflict_line "$files")"
      notify_conflict "$pr" "$files" main
      return 0
    fi
  fi
  if [ "$(pr_rollup "$head")" != green ]; then
    run=$(latest_run "$hb"); run_id=${run%%	*}
    run_status=$(printf '%s' "$run" | cut -f2)
    rate_stop
    why="not green yet, nothing merged"
    code=2
    if [ -n "$run_id" ] && [ "$run_status" != completed ] && [ -n "$run_status" ]; then
      # Re-run (gh_write run rerun --failed): the old attempt's red checks still
      # show on the commit for a few seconds while the new attempt starts.
      # A run that is not completed is pending, whatever its old checks say.
      code=2; msg="its run is $run_status (a new attempt)"
    elif [ -n "$run_id" ]; then
      code=0; msg=$(diagnose "$run_id") || code=$?
      case $code in
        1) record_flaky "$pr" "$run_id" failed; why="$msg" ;;
        3) why="$msg" ;;
        4)
          # A job cancelled before a runner took it is not a failure:
          # re-run it and wait, rather than give up.
          gh_write run rerun "$run_id" >/dev/null 2>&1 || true
          # A drain on a CI runner does not hold it for the re-run: the run's
          # end starts a drain of its own (queue/wait.sh).
          if [ -n "$QUEUE_IN_DRAIN" ] && [ "$(drain_wait_where)" = end ]; then batch_line "$pr" "waiting" "$msg; re-ran it, and a drain starts again when it finishes"; return 0; fi
          batch_line "$pr" "waiting" "$msg; re-ran it and waiting for the result"
          if wait_for_run "$pr" "$hb"; then rm -f "$flaky_dir/pr-$pr.tsv"; serial_one "$pr"; return 0; fi
          return 0 ;;
      esac
    fi
    # Run by hand on a pull request whose checks are still running,
    # --serial waits for them and merges, once, rather than leaving its
    # caller to wait and run it again. A red run is said, never waited on;
    # a drain moves on and comes back next round.
    if [ -z "$QUEUE_IN_DRAIN" ] && [ -z "${serial_waited:-}" ] && { [ "$code" = 0 ] || [ "$code" = 2 ]; }; then
      serial_waited=1
      batch_line "$pr" "waiting" "its checks are still running; waiting for them (up to ${QUEUE_WAIT_MINUTES:-60} minutes), then merging"
      if wait_for_run "$pr" "$hb"; then rm -f "$flaky_dir/pr-$pr.tsv" 2>/dev/null; serial_one "$pr"; return 0; fi
    fi
    batch_line "$pr" "waiting" "$why"
    return 0
  fi
  nr=$(needs_rerun "$pr_classes" "$main_classes" "$(rerun_free_classes "$rules")")
  ms=""; [ "$nr" = yes ] && ms=$(main_state)
  merged_why="main moved only outside its classes"
  [ "$nr" = yes ] && merged_why="main moved in its classes, but it merges cleanly and main is green; the full run on main is the gate"
  # A rush one tested on main plus those ahead, now landed: that run is its result.
  if [ "${QUEUE_CHAIN_PROVEN:-}" = yes ]; then nr=no; merged_why="tested on main plus the rush change ahead of it, which has landed; it merges on that result"; fi
  if [ "$(rerun_decision "$nr" "$ms" "${QUEUE_RERUN:-green-main}")" = update ]; then
    if ! gh_write api -X PUT "repos/{owner}/{repo}/pulls/$pr/update-branch" >/dev/null 2>"$gh_err"; then
      rate_stop
      case "$(cat "$gh_err" 2>/dev/null)" in
        *onflict*) batch_line "$pr" "not merged" "$(conflict_line "$(git merge-tree --write-tree --name-only origin/"$base" "$head" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')")" ;;
        *) batch_line "$pr" "not merged" "GitHub refused to update the branch: $(head -n 1 "$gh_err" 2>/dev/null)" ;;
      esac
      return 0
    fi
    sync_worktree "$hb"
    # Main brought template changes in: derive the known-hashes list in the
    # branch's own worktree, commit it there and push, so the run sees it.
    kr_note=""; kr_path=$(worktree_of "$hb")
    if [ -n "$kr_path" ]; then
      kr_line=$(known_refresh "$kr_path" "$head")
      if [ -n "$kr_line" ]; then
        if git -C "$kr_path" push -q origin "HEAD:$hb" >/dev/null 2>&1; then kr_note="; $kr_line"; else kr_note="; $kr_line, but the push was refused, so push it from its worktree"; fi
      fi
    fi
    batch_line "$pr" "updated" "main moved in its classes (PR: ${pr_classes:-none}; main: ${main_classes:-none}) and main is ${ms:-not known to be green}, so CI runs again$kr_note"
    # Run by hand, --serial waits for that run and merges, rather than
    # leaving its caller to loop; once only, so a main that keeps moving
    # is said, not chased. A drain moves on and comes back next round.
    if [ -z "$QUEUE_IN_DRAIN" ] && [ -z "${serial_refreshed:-}" ]; then
      serial_refreshed=1
      sleep 20
      rm -f "$flaky_dir/pr-$pr.tsv" 2>/dev/null
      if wait_for_run "$pr" "$hb"; then serial_one "$pr"; fi
    fi
    return 0
  fi
  head_branch=$hb
  why=$(migration_blocks "$pr")
  if [ -n "$why" ]; then batch_line "$pr" "refused" "$why"; return 0; fi
  rq=$(required_on "$head")
  # The same for the required check alone: by hand, wait for it once.
  if [ "$rq" = pending ] && [ -z "$QUEUE_IN_DRAIN" ] && [ -z "${serial_waited:-}" ]; then
    serial_waited=1
    batch_line "$pr" "waiting" "the required check \"${QUEUE_SUMMARY_CHECK:-CI passed}\" is still running; waiting for it, then merging"
    wait_required "$head" >/dev/null 2>&1 || true
    rq=$(required_on "$head")
  fi
  if [ "$rq" != passed ]; then
    batch_line "$pr" "waiting" "the required check \"${QUEUE_SUMMARY_CHECK:-CI passed}\" is $rq on its head commit; GitHub refuses the merge until it passes"
    return 0
  fi
  record_flaky "$pr" "" passed
  wait_quiet_main
  gh_write api -X PUT "repos/{owner}/{repo}/pulls/$pr/merge" -f merge_method=squash -f commit_title="$(serial_title "$(pr_field "$pr" 3)" "$pr" "${because:-alone}")" >/dev/null 2>"$gh_err" || { rate_stop; batch_line "$pr" "not merged" "GitHub refused the merge: $(head -n 1 "$gh_err" 2>/dev/null)$(workflow_wait_note "$gh_err")"; return 0; }
  batch_line "$pr" "merged serially" "$merged_why"; ci_dispatch "$base"
  tidy_worktree "$head_branch"
}

# tidy_worktree BRANCH: remove the worktree of a branch that just merged,
# when it is clean. The branch itself is kept. Quiet when there is none.
tidy_worktree() {
  [ -n "$1" ] && [ -f "$here/../worktrees.sh" ] || return 0
  sh "$here/../worktrees.sh" prune --apply --branch "$1" 2>/dev/null | grep '^removed' || true
}

# queue_serial: the --serial mode, run by merge-queue.sh once the lock is taken.
queue_serial() {
  # The rule lives here, not only in a hook on the command line: a script
  # that wraps the queue hides the call from the hook. Run by a drain or a
  # batch, the choice was already made.
  if [ -z "$QUEUE_IN_DRAIN" ] && [ -z "$because" ]; then
    why=$(serial_refusal "$(ready_others "$(printf '%s ' $prs)")" "$because")
    if [ -n "$why" ]; then say "Refused --serial: $why"; exit 2; fi
  fi
  [ -n "$because" ] || { [ -n "$QUEUE_IN_DRAIN" ] && because=drain; }
  s_begin=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
  for pr in $prs; do serial_one "$pr"; done
  if [ -z "$QUEUE_IN_DRAIN" ]; then deploy_if_due "$s_begin"; fi
  exit 0
}
