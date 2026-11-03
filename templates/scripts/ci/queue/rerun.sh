#!/bin/sh
# The drain's one retry of a red or cancelled pull request, with the reason
# it needs (scripts/ci/QUEUE.md, "A re-run needs a reason"). Sourced by
# scripts/ci/merge-queue.sh; functions only. The rules are red_rerun and
# rerun_choice; this reads the facts and acts on the answer.

# drain_rerun_one PR: re-run the failed jobs of PR's newest run on its head,
# or say why not. Reads $open, $round and $cancel_heads from the drain and
# records the head and text it looked at in a comment on the pull request
# (rerun_note), so the next drain, which may start on a runner with nothing
# remembered, does not re-run the same failure on the same commit.
drain_rerun_one() {
  dr_pr=$1
  dr_rb=$(pr_field "$dr_pr" 1)
  dr_head=$(pr_field "$dr_pr" 2)
  dr_runs=$(gh api "repos/{owner}/{repo}/actions/workflows/${QUEUE_CI_WORKFLOW:-ci.yml}/runs?branch=$dr_rb&per_page=20" --jq '.workflow_runs[] | [.id, .head_sha, .status, (.conclusion // "")] | @tsv' 2>/dev/null)
  # Only the newest run on the current head, only when no run of the pull
  # request is queued or running, and a cancelled head once: re-running an
  # older run cancels the fresh one through CI's concurrency group.
  dr_choice=$(rerun_choice "$dr_runs" "$dr_head" "$cancel_heads")
  case "$dr_choice" in
    rerun\ *)
      dr_rid=${dr_choice#rerun }
      dr_why="a cancelled head, once"
      if [ "$(printf '%s\n' "$open" | awk -F'\t' -v n="$dr_pr" '$1 == n { print $4 }')" = red ]; then
        dr_text=$(gh api "repos/{owner}/{repo}/pulls/$dr_pr" --jq '.title + "\n" + (.body // "")' 2>/dev/null)
        dr_mark=$(body_mark "$dr_text")
        dr_edited=$(time_after "$(gh api "repos/{owner}/{repo}/pulls/$dr_pr" --jq '.updated_at' 2>/dev/null | tr -d '\r')" "$(gh api "repos/{owner}/{repo}/actions/runs/$dr_rid" --jq '.updated_at' 2>/dev/null | tr -d '\r')")
        dr_seen=$(rerun_marks "$(gh api "repos/{owner}/{repo}/issues/$dr_pr/comments?per_page=100" --jq '.[].body' 2>/dev/null)")
        dr_call=$(red_rerun "$(run_jobs_text "$dr_rid")" "$dr_seen" "$dr_head" "$dr_mark" "$dr_edited")
        if [ "$(rerun_seen "$dr_seen" "$dr_head" "$dr_mark")" != same ]; then
          gh_write api -X POST "repos/{owner}/{repo}/issues/$dr_pr/comments" -f body="$(rerun_note "$dr_call" "$dr_head" "$dr_mark")" >/dev/null 2>&1 || true
        fi
        dr_why=${dr_call#* }
        if [ "${dr_call%% *}" = skip ]; then
          say "round $round: #$dr_pr is red and not re-run: $dr_why; it is its agent's turn (push, or edit the pull request)."
          return 0
        fi
      fi
      if gh_write api -X POST "repos/{owner}/{repo}/actions/runs/$dr_rid/rerun-failed-jobs" >/dev/null 2>&1; then
        say "round $round: #$dr_pr re-running the failed jobs of its newest run ($dr_why)."
      fi
      cancel_heads="$cancel_heads $dr_head" ;;
    twice) attention=$(printf '%s\n%s\tcancelled twice; look at it\n' "$attention" "$dr_pr" | sed '/^$/d' | sort -u -n) ;;
    wait) say "round $round: #$dr_pr has a CI run queued or running; not re-running an older one." ;;
  esac
}
