#!/bin/sh
# Rush changes: "land this next" reserves the machines.
# Sourced by scripts/ci/merge-queue.sh; functions only.

# --- Rush changes: "land this next" reserves the machines ---
# At every tick a land-next request is open, the queue cancels the running
# and queued checks of every other pull request (never a batch's run, a
# rush test head's or a run on main; rush_cancel_pick), notes each as
# paused in rush.paused for the published state, and leaves the machines
# to the rush ones. The rush list is a chain: each one after the first is
# tested on a test head of main plus those ahead of it, built as the batch
# builds its members, so it merges on that result once they have landed.
# When the list is empty, every paused check is re-run once, oldest first.

# rush_keep: the open pull requests never paused: batches and test heads.
rush_keep() {
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select((.body // "") | (contains("<!-- merge-queue:batch -->") or contains("<!-- merge-queue:rush -->") or startswith("One integration run for the pull requests below"))) | .number' 2>/dev/null | tr -d '\r' | tr '\n' ' '
}

# rush_pause_others RUSH: cancel and note every other pull request's checks.
rush_pause_others() {
  rp_runs=$(for rp_s in in_progress queued; do gh api "repos/{owner}/{repo}/actions/runs?status=$rp_s&per_page=100" --jq '.workflow_runs[] | [.id, .status, .event, .head_branch, ((.pull_requests[0].number // "") | tostring), .head_sha] | @tsv' 2>/dev/null; done | tr -d '\r')
  rush_cancel_pick "$rp_runs" "$base" "$1 $(rush_keep)" | while IFS="$tab" read -r rp_run rp_pr rp_head; do
    [ -n "$rp_run" ] || continue
    grep -qx "$rp_run" "$flaky_dir/rush.cancelled" 2>/dev/null && continue
    if gh_write api -X POST "repos/{owner}/{repo}/actions/runs/$rp_run/cancel" >/dev/null 2>&1; then
      printf '%s\n' "$rp_run" >> "$flaky_dir/rush.cancelled"
      printf '%s\t%s\t%s\t%s\n' "$rp_pr" "$rp_run" "$(date +%s)" "$rp_head" >> "$flaky_dir/rush.paused"
      say "rush: paused #$rp_pr's checks (run $rp_run) for #$(printf '%s' "$1" | awk '{print $1}'); they run again once the rush list has landed."
    fi
  done
  return 0
}

# rush_machines RUSH: one row a machine in rush.machines, for the published
# state. A machine is free only when GitHub lists no job on it.
rush_machines() {
  rm_runners=$(gh api "repos/{owner}/{repo}/actions/runners" --jq '.runners[] | "\(.name)\t\(.status)"' 2>/dev/null | tr -d '\r')
  if [ -z "$rm_runners" ]; then : > "$flaky_dir/rush.machines"; return 0; fi
  rm_jobs=$(gh api "repos/{owner}/{repo}/actions/runs?status=in_progress&per_page=50" --jq '.workflow_runs[].id' 2>/dev/null | tr -d '\r' | while read -r rm_id; do
    [ -n "$rm_id" ] || continue
    gh api "repos/{owner}/{repo}/actions/runs/$rm_id/jobs?filter=latest&per_page=100" --jq '.jobs[] | select(.status != "completed" and (.runner_name // "") != "") | "\(.runner_name)\t\(.run_id)\t\([.steps[]? | select(.status == "in_progress") | .name] | first // "")"' 2>/dev/null
  done | tr -d '\r')
  rm_wait=""
  for rm_p in $1; do
    rm_q=$(gh api "repos/{owner}/{repo}/commits/$(pr_field "$rm_p" 2)/check-runs?per_page=100" --jq '[.check_runs[] | select(.status == "queued")] | length' 2>/dev/null | tr -d '\r')
    if [ "${rm_q:-0}" -gt 0 ] 2>/dev/null; then rm_wait=$rm_p; break; fi
  done
  runner_rows "$rm_runners" "$rm_jobs" "$(cat "$flaky_dir/rush.cancelled" 2>/dev/null)" "$rm_wait" > "$flaky_dir/rush.machines"
  return 0
}

# rush_build_head PR AHEAD NAME: main, then each one ahead, then PR, merged
# in order with merge commits as the batch merges its members, pushed to
# NAME and opened as a draft so CI tests it. Prints the draft's number.
rush_build_head() {
  fetch_base || return 1
  rb_c=$(git rev-parse "origin/$base") || return 1
  rb_refs=""
  for rb_p in $2 $1; do
    rb_h=$(fetch_pr_head "$rb_p") || return 1
    rb_out=$(git merge-tree --write-tree "$rb_c" "$rb_h" 2>/dev/null) || return 1
    rb_c=$(git commit-tree "$(printf '%s\n' "$rb_out" | head -n 1)" -p "$rb_c" -p "$rb_h" -m "Merge #$rb_p into the rush test head $3") || return 1
    rb_refs="$rb_refs$(carried_refs "$(gh api "repos/{owner}/{repo}/pulls/$rb_p" --jq '.body // ""' 2>/dev/null)" "$rb_p" | grep -v '^Closes ')
"
  done
  git push -q origin "$rb_c:refs/heads/$3" 2>/dev/null || return 1
  rb_body=$(printf '%s\nThe rush test head for #%s: main plus%s plus it, merged in that order. The queue opened it so #%s is tested behind those ahead of it and merges on this result once they land; it is never merged itself.\n\n%s\n' "$RUSH_MARKER" "$1" "$(printf ' #%s' $2)" "$1" "$(printf '%s' "$rb_refs" | awk 'NF && !seen[$0]++')")
  gh_write api -X POST "repos/{owner}/{repo}/pulls" -f base="$base" -f head="$3" -f title="Rush test head: #$1 on main plus$(printf ' #%s' $2)" -f body="$rb_body" -F draft=true --jq .number 2>/dev/null | tr -d '\r'
}

# rush_heads RUSH: a test head for each one with others ahead of it; a test
# head whose own pull request left the list, or one of whose members ahead
# neither landed nor stays in the list, is closed with a comment.
rush_heads() {
  touch "$flaky_dir/rush.heads"
  rush_chain "$1" | while IFS="$tab" read -r rh_pr rh_ahead; do
    [ -n "$rh_ahead" ] || continue
    rh_name=$(rush_head_name "$rh_pr" "$rh_ahead")
    awk -F'\t' -v n="$rh_name" '$2 == n { f = 1 } END { exit !f }' "$flaky_dir/rush.heads" && continue
    if rh_num=$(rush_build_head "$rh_pr" "$rh_ahead" "$rh_name") && [ -n "$rh_num" ]; then
      printf '%s\t%s\t%s\t%s\n' "$rh_pr" "$rh_name" "$rh_num" "$rh_ahead" >> "$flaky_dir/rush.heads"
      say "rush: testing #$rh_pr on main plus$(printf ' #%s' $rh_ahead) (test head #$rh_num)."
    else
      say "rush: #$rh_pr could not be built on main plus$(printf ' #%s' $rh_ahead); its agent merges the one ahead in before its turn."
    fi
  done
  awk -F'\t' 'NF >= 3 && $5 != "closed"' "$flaky_dir/rush.heads" | while IFS="$tab" read -r rh_pr rh_name rh_num rh_ahead; do
    rh_end=""
    case " $1 " in *" $rh_pr "*) ;; *) rh_end="#$rh_pr has left the rush list" ;; esac
    for rh_a in $rh_ahead; do
      [ -z "$rh_end" ] || break
      case " $1 " in *" $rh_a "*) continue ;; esac
      [ "$(gh api "repos/{owner}/{repo}/pulls/$rh_a" --jq .merged 2>/dev/null)" = true ] || rh_end="#$rh_a ahead of it did not land, so #$rh_pr is tested again without it"
    done
    [ -n "$rh_end" ] || continue
    gh_write api -X POST "repos/{owner}/{repo}/issues/$rh_num/comments" -f body="Closed by the queue: $rh_end." >/dev/null 2>&1 || true
    gh_write api -X PATCH "repos/{owner}/{repo}/pulls/$rh_num" -f state=closed >/dev/null 2>&1 || true
    awk -F'\t' -v OFS='\t' -v n="$rh_name" '$2 == n { $5 = "closed" } { print }' "$flaky_dir/rush.heads" > "$flaky_dir/rush.heads.new" && mv "$flaky_dir/rush.heads.new" "$flaky_dir/rush.heads"
  done
  return 0
}

# rush_proof PR SHA: "green<TAB>yes" when its last test head is green and
# main plus SHA is the very tree that head tested.
rush_proof() {
  rf_l=$(awk -F'\t' -v p="$1" '$1 == p && $5 != "closed" { l = $3; n = $2 } END { print l " " n }' "$flaky_dir/rush.heads" 2>/dev/null)
  rf_name=${rf_l#* }; rf_l=${rf_l%% *}
  [ -n "$rf_l" ] || return 0
  rf_sha=$(gh api "repos/{owner}/{repo}/pulls/$rf_l" --jq .head.sha 2>/dev/null | tr -d '\r')
  [ -n "$rf_sha" ] || return 0
  rf_same=""
  if fetch_base "+refs/heads/$rf_name:refs/queue/$rf_name" && rf_t=$(git merge-tree --write-tree "origin/$base" "$2" 2>/dev/null); then
    [ "$(printf '%s\n' "$rf_t" | head -n 1)" = "$(git rev-parse "$rf_sha^{tree}" 2>/dev/null)" ] && rf_same=yes
  fi
  printf '%s\t%s\n' "$(pr_rollup "$rf_sha")" "$rf_same"
}

# rush_resume: the rush list is empty; re-run every paused check once,
# oldest first, by the newest-run-on-current-head rule, then go on.
rush_resume() {
  [ -s "$flaky_dir/rush.paused" ] || return 0
  for ru_pr in $(rush_reruns "$(cat "$flaky_dir/rush.paused")"); do
    ru_info=$(gh api "repos/{owner}/{repo}/pulls/$ru_pr" --jq '"\(.state)\t\(.head.ref)\t\(.head.sha)"' 2>/dev/null | tr -d '\r')
    [ "${ru_info%%	*}" = open ] || continue
    ru_rest=${ru_info#*	}; ru_ref=${ru_rest%%	*}; ru_sha=${ru_rest#*	}
    ru_runs=$(gh api "repos/{owner}/{repo}/actions/workflows/${QUEUE_CI_WORKFLOW:-ci.yml}/runs?branch=$ru_ref&per_page=20" --jq '.workflow_runs[] | [.id, .head_sha, .status, (.conclusion // "")] | @tsv' 2>/dev/null)
    rr_pick=$(rerun_choice "$ru_runs" "$ru_sha" "")
    case "$rr_pick" in
      rerun\ *)
        if gh_write api -X POST "repos/{owner}/{repo}/actions/runs/${rr_pick#rerun }/rerun-failed-jobs" >/dev/null 2>&1; then say "rush: re-ran #$ru_pr's paused checks, now the rush list has landed."; fi ;;
      wait) say "rush: #$ru_pr already has a run going on its head; not re-running an older one." ;;
    esac
  done
  cat "$flaky_dir/rush.paused" >> "$flaky_dir/rush.resumed"
  : > "$flaky_dir/rush.paused"; : > "$flaky_dir/rush.cancelled"; : > "$flaky_dir/rush.machines"
  return 0
}

# rush_tick RUSH: the rush list as asked, at every tick.
rush_tick() {
  printf '%s\n' $1 | sed '/^$/d' > "$flaky_dir/rush.list"
  if [ -z "$(printf '%s' "$1" | tr -d ' \n')" ]; then
    [ -s "$flaky_dir/rush.heads" ] && rush_heads ""
    rush_resume
    return 0
  fi
  rush_pause_others "$1"
  rush_heads "$1"
  rush_machines "$1"
  return 0
}

