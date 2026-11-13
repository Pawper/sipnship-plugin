#!/bin/sh
# Held steps, at a drain's end.
# Sourced by scripts/ci/merge-queue.sh; functions only.

# held_steps: at a drain's end, before unsticking, read the waits agents
# recorded on their pull requests (scripts/ci/wait-for.sh: the queue:after
# label and a hidden merge-queue:after mark in a comment). For each wait
# whose pull request has landed: merge main in when that was the step (one
# a drain's end, and never while another pull request's CI runs), or name
# the waiting session in the report ("Wake: ..."), and mark the wait done.
# Writes the waits still open to $flaky_dir/after.tsv, which the published
# state carries. Sets held_merged=yes when it merged main into one, so the
# drain's end starts no second re-merge. QUEUE_HELD_STEPS=off turns it off.
held_steps() {
  held_merged=no
  [ "${QUEUE_HELD_STEPS:-on}" != off ] || return 0
  hs_out="$flaky_dir/after.tsv.new"; : > "$hs_out"
  # One listing of the labelled pull requests. A held change uses no runners until the builder lets it land, so main is never merged into it: its wait stays recorded.
  hs_list=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select([.labels[].name] | index("queue:after")) | "\(.number)\u001f\([.labels[].name] | join(","))\u001f\((.body // "") | gsub("[\r\n]+"; " | "))"' 2>/dev/null | tr -d '\r')
  hs_prs=""; hs_held=""
  while IFS="$(printf '\037')" read -r hh_num hh_labels hh_body; do
    [ -n "$hh_num" ] || continue
    hs_prs="$hs_prs $hh_num"
    hh_why=$(held_reason "$(printf '%s' "$hh_labels" | tr ',' '\n')" "$(printf '%s' "$hh_body" | sed 's/ | /\
/g')")
    [ -z "$hh_why" ] || hs_held="$hs_held $hh_num"
  done <<EOF
$hs_list
EOF
  hs_busy=""
  for hs_pr in $hs_prs; do
    hs_marks=$(after_marks "$(gh api "repos/{owner}/{repo}/issues/$hs_pr/comments?per_page=100" --jq '.[].body' 2>/dev/null)")
    hs_left=0
    while IFS="$tab" read -r hs_after hs_step hs_ses hs_words; do
      [ -n "$hs_after" ] || continue
      hs_landed=no
      [ -n "$(gh api "repos/{owner}/{repo}/pulls/$hs_after" --jq '.merged_at // ""' 2>/dev/null | tr -d '\r')" ] && hs_landed=yes
      if [ "$hs_landed" = yes ] && [ "$hs_step" = merge-main ] && [ -z "$hs_busy" ]; then
        # One CI run at a time: busy when another open pull request is still checking, or this drain's end merged one already.
        if [ "$held_merged" = yes ]; then hs_busy=yes
        else
          hs_busy=no
          for hs_o in $(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select(.draft == false) | .head.sha' 2>/dev/null | tr -d '\r'); do
            if [ "$(pr_rollup "$hs_o")" = pending ]; then hs_busy=yes; break; fi
          done
        fi
      fi
      [ "$held_merged" = yes ] && hs_busy=yes
      hs_act=$(after_action "$hs_step" "$hs_landed" "${hs_busy:-no}")
      case " $hs_held " in *" $hs_pr "*) [ "$hs_act" != merge ] || hs_act=held ;; esac
      case "$hs_act" in
        held)
          say "Held step: #$hs_after landed, but #$hs_pr is held for its builder, so main is not merged into it."
          hs_left=$((hs_left + 1)); printf '%s\t%s\t%s\t%s\t%s\n' "$hs_pr" "$hs_after" "$hs_step" "$hs_ses" "$hs_words" >> "$hs_out" ;;
        merge)
          if gh_write api -X PUT "repos/{owner}/{repo}/pulls/$hs_pr/update-branch" >/dev/null 2>"$gh_err"; then
            gh_write api -X POST "repos/{owner}/{repo}/issues/$hs_pr/comments" -f body="$(after_note merged "$hs_after")" >/dev/null 2>&1 || true
            say "Held step: #$hs_after landed, so main was merged into #$hs_pr as its agent recorded; CI runs on the new commit."
            sync_worktree "$(pr_field "$hs_pr" 1)"
            held_merged=yes
          else
            rate_stop
            say "Held step: GitHub refused to merge main into #$hs_pr: $(head -n 1 "$gh_err" 2>/dev/null | tr -d '\r')"
            hs_left=$((hs_left + 1)); printf '%s\t%s\t%s\t%s\t%s\n' "$hs_pr" "$hs_after" "$hs_step" "$hs_ses" "$hs_words" >> "$hs_out"
          fi ;;
        wake)
          gh_write api -X POST "repos/{owner}/{repo}/issues/$hs_pr/comments" -f body="$(after_note wake "$hs_after" "$hs_words")" >/dev/null 2>&1 || true
          say "$(after_wake_line "$hs_pr" "$hs_after" "$hs_ses" "$hs_words")" ;;
        *)
          [ "$hs_landed" = yes ] && say "Held step: #$hs_after landed; main is merged into #$hs_pr at a drain's end with no other CI running."
          hs_left=$((hs_left + 1)); printf '%s\t%s\t%s\t%s\t%s\n' "$hs_pr" "$hs_after" "$hs_step" "$hs_ses" "$hs_words" >> "$hs_out" ;;
      esac
    done <<EOF
$hs_marks
EOF
    # Nothing left waiting on it: the label goes, so the next drain reads no comments for it.
    [ "$hs_left" -gt 0 ] || gh_write api -X DELETE "repos/{owner}/{repo}/issues/$hs_pr/labels/queue:after" >/dev/null 2>&1 || true
  done
  mv -f "$hs_out" "$flaky_dir/after.tsv" 2>/dev/null || true
  return 0
}
