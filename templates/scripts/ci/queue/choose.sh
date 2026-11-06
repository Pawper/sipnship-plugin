#!/bin/sh
# What may be queued, and what is wrong with a pull request that may
# not: its folder, its migrations, its head, a hold, a conflict, a red run.
# Sourced by scripts/ci/merge-queue.sh; functions only.

# worktree_of BRANCH: the local worktree that has the branch checked out.
worktree_of() {
  command -v worktree_for_branch >/dev/null 2>&1 || return 0
  worktree_for_branch "$(worktree_branches "$(git worktree list --porcelain)")" "$1"
}

# folder_blocks PR: print why a PR may not be queued when its worktree has
# uncommitted files outside .scratch/. The folder is checked when the PR is
# queued, not after the merge, so a file written minutes before is caught.
folder_blocks() {
  fb_branch=$(pr_field "$1" 1)
  fb_path=$(worktree_of "$fb_branch")
  [ -n "$fb_path" ] || return 0
  fb_dirty=$(dirty_non_scratch "$(git -C "$fb_path" status --porcelain 2>/dev/null)")
  [ -n "$fb_dirty" ] || return 0
  printf 'its worktree has %s uncommitted file(s) outside .scratch/, first: %s\n' \
    "$(printf '%s\n' "$fb_dirty" | wc -l | tr -d ' ')" "$(printf '%s\n' "$fb_dirty" | head -n 1)"
}

# migration_blocks PR: print why a PR may not merge yet when it adds a
# migration that its own copy of the manual does not mark as done. A change
# that needs a migration run merges after the run, not before. The manual
# is SETUP.md or the "manual" line in setup-paths.txt; migrations are the
# "migration" kind in .claude/numbering.txt.

# fetch_pr_head PR [DIR]: put the pull request's head commit at
# refs/queue/pr-PR (in DIR, default here) and print it. GitHub's pull ref
# (refs/pull/N/head) can lag the branch by half an hour, so when it is not
# the head the pull request reports, the branch itself is fetched. Prints
# nothing and returns 1 when neither has the head yet, with the reason in
# $fph_why.
fetch_pr_head() {
  fph_dir=${2:-.}
  fph_want=$(pr_field "$1" 2)
  git -C "$fph_dir" fetch -q origin "+refs/pull/$1/head:refs/queue/pr-$1" 2>/dev/null || true
  fph_got=$(git -C "$fph_dir" rev-parse -q --verify "refs/queue/pr-$1" 2>/dev/null || true)
  if [ -n "$fph_want" ] && [ "$fph_got" != "$fph_want" ]; then
    fph_branch=$(pr_field "$1" 1)
    if [ -n "$fph_branch" ] && git -C "$fph_dir" fetch -q origin "+refs/heads/$fph_branch:refs/queue/pr-$1" 2>/dev/null; then
      fph_got=$(git -C "$fph_dir" rev-parse -q --verify "refs/queue/pr-$1" 2>/dev/null || true)
    fi
  fi
  if [ -z "$fph_got" ]; then fph_why="its head could not be fetched"; return 1; fi
  if [ -n "$fph_want" ] && [ "$fph_got" != "$fph_want" ]; then
    fph_why="GitHub's copy of it is behind its branch (has $(printf '%.7s' "$fph_got"), the branch is at $(printf '%.7s' "$fph_want")); GitHub usually catches up within minutes, so it waits for the next round, not a failure"
    return 1
  fi
  printf '%s\n' "$fph_got"
}

migration_blocks() {
  [ -f .claude/numbering.txt ] || return 0
  mb_glob=$(numbering_glob "$(cat .claude/numbering.txt)" migration)
  [ -n "$mb_glob" ] || return 0
  mb_manual=SETUP.md
  [ -f "$here/setup-paths.txt" ] && mb_manual=$(setup_manual "$(cat "$here/setup-paths.txt")")
  # A gate that cannot look must block, not pass: a fetch that failed once
  # let two unrun migrations onto main.
  # Fetch the pull request into a ref of its own and read that. Fetching
  # main and the pull request together and then reading FETCH_HEAD names
  # main, the first ref fetched: the gate compared main with itself, saw
  # no migration added, and let three unrun migrations through.
  git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null || { echo "its migrations could not be checked (fetching $base failed); it waits for the next round"; return 0; }
  # The head as the pull request reports it, from its pull ref or, when
  # GitHub's pull ref lags, its branch.
  mb_head=$(fetch_pr_head "$1") || { echo "its migrations could not be checked yet: $fph_why"; return 0; }
  mb_added=$(git diff --name-only --diff-filter=A "origin/$base...$mb_head" 2>/dev/null)
  # Files added under a migrations folder that the glob does not match
  # mean the glob is wrong, and the gate would see nothing; say so.
  mb_stray=$(printf '%s\n' "$mb_added" | tr '\\' '/' | awk '/(^|\/)migrations\//' | while IFS= read -r mb_f; do
    [ -n "$mb_f" ] || continue
    set -f; case "$mb_f" in $mb_glob) ;; *) printf '%s\n' "$mb_f" ;; esac; set +f
  done | head -n 1)
  if [ -n "$mb_stray" ]; then echo "it adds $mb_stray under a migrations folder that the migration glob in .claude/numbering.txt ($mb_glob) does not match; fix the glob so the gate can see it"; return 0; fi
  mb_pending=$(pending_migrations "$(git show "$mb_head:$mb_manual" 2>/dev/null)" "$mb_added" "$mb_glob")
  [ -n "$mb_pending" ] || return 0
  printf '%s\n' "$mb_pending" | head -n 1 | awk -F'\t' -v m="$mb_manual" '{ printf "it adds migration %s, which is %s in %s; run it, mark it Done in the manual on this branch, then queue it again\n", $1, $2, m }'
}

# serial_one PR: today's behavior for one PR.
# pr_held PR: why this pull request is held, or nothing.
pr_held() {
  held_reason "$(gh api "repos/{owner}/{repo}/issues/$1/labels" --jq '.[].name' 2>/dev/null)" "$(gh api "repos/{owner}/{repo}/pulls/$1" --jq '.body // ""' 2>/dev/null)"
}

# why_red PR: the failing check runs on the pull request's head, by name,
# and the first lines of each job's log that look like an error, so
# "failed CI twice" comes with its cause instead of three more calls.
why_red() {
  wr_sha=$(pr_field "$1" 2)
  wr_jobs=$(gh api "repos/{owner}/{repo}/commits/$wr_sha/check-runs?per_page=100" --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "startup_failure" or .conclusion == "action_required" or .conclusion == "timed_out") | "\(.name)\t\(.id)"' 2>/dev/null || true)
  [ -n "$wr_jobs" ] || { echo "    (no failing check run on its head commit now; it may have gone green since)"; return 0; }
  printf '%s\n' "$wr_jobs" | while IFS="$tab" read -r wr_name wr_id; do
    [ -n "$wr_name" ] || continue
    wr_lines=$(gh api "repos/{owner}/{repo}/actions/jobs/$wr_id/logs" 2>/dev/null | tr -d '\r' | grep -E 'error|Error|FAIL|AssertionError' | grep -v '^[[:space:]]*$' | head -n 3 | cut -c1-160)
    if [ -n "$wr_lines" ]; then
      echo "    $wr_name failed:"
      printf '%s\n' "$wr_lines" | sed 's/^/      /'
    else
      echo "    $wr_name failed (its log could not be read; open the run)"
    fi
  done
}

# notify_conflict PR FILES WITH: comment on the pull request and label it
# state:blocked, once per head commit, so the owning agent finds the
# conflict on its next session instead of it waiting until someone looks.
notify_conflict() {
  nc_sha=$(pr_field "$1" 2)
  nc_seen="$flaky_dir/noticed"
  grep -qx "$1 $nc_sha" "$nc_seen" 2>/dev/null && return 0
  # A clash with main is marked in the comment itself, so a drain on
  # another machine (the scheduled one) never comments twice on one head.
  nc_mark=""
  if [ "$3" = main ] && [ -n "$nc_sha" ]; then
    if unstick_marks "$(gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --jq '.[].body' 2>/dev/null)" | grep -qx "clash $nc_sha"; then
      echo "$1 $nc_sha" >> "$nc_seen"; return 0
    fi
    nc_mark=$(printf '\n%s' "$(unstick_mark clash "$nc_sha")")
  fi
  gh_write api -X POST "repos/{owner}/{repo}/issues/$1/comments" -f body="$(conflict_notice "$2" "$3" "${4:-}")$nc_mark" >/dev/null 2>&1 || return 0
  nc_cur=$(gh api "repos/{owner}/{repo}/issues/$1/labels" --jq '.[].name' 2>/dev/null || true)
  nc_label=$(state_label blocked "$(project_label_form)")
  state_labels_json "$nc_cur" "$nc_label" | gh_write api -X PUT "repos/{owner}/{repo}/issues/$1/labels" --input - >/dev/null 2>&1 || true
  echo "$1 $nc_sha" >> "$nc_seen"
  say "  #$1: commented with the conflicting files and labeled it $nc_label."
}

# ready_others EXCLUDE: the open pull requests aimed at the base, not
# drafts, green and not conflicting with main, other than EXCLUDE.
ready_others() {
  gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, (.draft | tostring), .head.sha, .base.ref] | @tsv' 2>/dev/null \
    | while IFS="$tab" read -r r_num r_draft r_sha r_base; do
      [ -n "$r_num" ] && [ "$r_draft" = false ] && [ "$r_base" = "$base" ] || continue
      case " $1 " in *" $r_num "*) continue ;; esac
      [ "$(pr_rollup "$r_sha")" = green ] || continue
      [ "$(mergeable_word "$(pr_field "$r_num" 5)")" != CONFLICTING ] || continue
      [ -z "$(pr_held "$r_num")" ] || continue
      printf '%s ' "$r_num"
    done
}

# run_jobs_text RUN_ID: one line per job of a CI run for outside_cause,
# "name<TAB>conclusion<TAB>failed step<TAB>annotations and error lines";
# the annotations and the log are read only for a job that did not pass.
run_jobs_text() {
  gh api "repos/{owner}/{repo}/actions/runs/$1/jobs?per_page=100" --jq '.jobs[] | [.name, (.conclusion // ""), ([.steps[]? | select(.conclusion == "failure") | .name][0] // ""), (.id | tostring)] | @tsv' 2>/dev/null | tr -d '\r' \
  | while IFS="$tab" read -r rj_name rj_conc rj_step rj_id; do
    [ -n "$rj_name" ] || continue
    rj_text=""
    case "$rj_conc" in
      success|skipped|neutral|'') ;;
      *)
        if [ "$rj_name" != "${QUEUE_SUMMARY_CHECK:-CI passed}" ]; then
          rj_text="$(gh api "repos/{owner}/{repo}/check-runs/$rj_id/annotations" --jq '[.[].message] | join("; ")' 2>/dev/null) $(gh api "repos/{owner}/{repo}/actions/jobs/$rj_id/logs" 2>/dev/null | grep -iE 'error|eperm|ebusy|econnreset|etimedout|lost communication|shutdown signal|lockfile' | head -n 12)"
        fi ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$rj_name" "$rj_conc" "$rj_step" "$(printf '%s' "$rj_text" | tr '\t\r\n' '   ' | cut -c1-2000)"
  done
}

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
  hs_prs=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select([.labels[].name] | index("queue:after")) | .number' 2>/dev/null | tr -d '\r')
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
      case "$(after_action "$hs_step" "$hs_landed" "${hs_busy:-no}")" in
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

# unstick_one: at a drain's end, unstick one open pull request, never two,
# so CI never runs two re-merges at once (scripts/ci/QUEUE.md,
# "Unsticking"). The rules are unstick_candidates, unstick_busy,
# outside_cause and unstick_action; this reads the facts and acts on the
# first pull request, in number order, the rules give an action. Held
# pull requests and an open batch's members are left alone, and so is
# everything while a rush change lands. QUEUE_UNSTICK=off turns it off.
unstick_one() {
  [ "${QUEUE_UNSTICK:-on}" != off ] || return 0
  # A missing list means no rush.
  [ ! -f "$flaky_dir/rush.list" ] || [ -z "$(tr -d ' \r\n' < "$flaky_dir/rush.list" 2>/dev/null)" ] || return 0
  rm -f "$flaky_dir/pr-"*.tsv 2>/dev/null
  us_listed=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | [.number, (.draft | tostring), .head.sha, .base.ref] | @tsv' 2>"$gh_err") || { say "Unsticking: the open pull requests could not be listed; nothing done."; return 0; }
  us_listed=$(drop_members "$us_listed" "${held:-} ${members:-}")
  us_open=$(printf '%s\n' "$us_listed" | tr -d '\r' | while IFS="$tab" read -r us_n us_d us_sha us_b; do
    [ -n "$us_n" ] && [ "$us_d" = false ] && [ "$us_b" = "$base" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$us_n" "$us_d" "$(mergeable_word "$(pr_field "$us_n" 5)")" "$(pr_rollup "$us_sha")" "$us_b"
  done)
  us_busy=$(unstick_busy "$us_open" "$base")
  git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null || { say "Unsticking: $base could not be fetched; nothing done."; return 0; }
  for us_pr in $(unstick_candidates "$us_open" "$base"); do
    us_row=$(printf '%s\n' "$us_open" | awk -F'\t' -v n="$us_pr" '$1 == n { print; exit }')
    us_mw=$(printf '%s' "$us_row" | cut -f3); us_roll=$(printf '%s' "$us_row" | cut -f4)
    us_head=$(fetch_pr_head "$us_pr") || continue
    us_behind=$(git rev-list --count "$us_head..origin/$base" 2>/dev/null || echo 0)
    us_merges=yes; us_files=""
    us_mt=$(git merge-tree --write-tree --name-only "origin/$base" "$us_head" 2>/dev/null) && us_rc=0 || us_rc=$?
    case $us_rc in
      0) ;;
      1) us_merges=no; us_files=$(printf '%s\n' "$us_mt" | sed -n '2,$p' | sed '/^$/,$d') ;;
      *) continue ;;
    esac
    us_runs=$(gh api "repos/{owner}/{repo}/actions/workflows/${QUEUE_CI_WORKFLOW:-ci.yml}/runs?head_sha=$us_head&per_page=10" --jq '.workflow_runs[] | [(.id | tostring), .status] | @tsv' 2>/dev/null | tr -d '\r')
    us_run=none; us_rid=""
    if [ -n "$us_runs" ]; then
      us_run=done; us_rid=$(printf '%s\n' "$us_runs" | head -n 1 | cut -f1)
      printf '%s\n' "$us_runs" | awk -F'\t' '$2 != "completed" { b = 1 } END { exit !b }' && us_run=busy
    fi
    us_cause=""
    if [ "$us_roll" = red ] && [ "$us_run" = done ]; then us_cause=$(outside_cause "$(run_jobs_text "$us_rid")" "${QUEUE_SUMMARY_CHECK:-CI passed}"); fi
    [ "$us_roll" = cancelled ] && us_cause=${us_cause:-a cancelled run}
    us_marks=$(unstick_marks "$(gh api "repos/{owner}/{repo}/issues/$us_pr/comments?per_page=100" --jq '.[].body' 2>/dev/null)")
    us_act=$(unstick_action "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$us_mw" "$us_roll" "$us_head" "$us_behind" "$us_merges" "$us_cause" "$us_run")" "$us_marks" "$us_busy")
    case "$us_act" in
      clash)
        say "Unsticking: #$us_pr conflicts with $base for real; asking its agent to merge $base in."
        notify_conflict "$us_pr" "$us_files" main
        return 0 ;;
      update)
        if gh_write api -X PUT "repos/{owner}/{repo}/pulls/$us_pr/update-branch" >/dev/null 2>"$gh_err"; then
          say "Unsticking: #$us_pr $( [ "$us_mw" = CONFLICTING ] && echo "showed a clash with $base that merges cleanly" || echo "was $us_behind commit(s) behind $base" ); merged $base into it, and CI runs on the new commit."
          sync_worktree "$(pr_field "$us_pr" 1)"
        else
          rate_stop
          say "Unsticking: GitHub refused to merge $base into #$us_pr: $(head -n 1 "$gh_err" 2>/dev/null | tr -d '\r')"
        fi
        return 0 ;;
      rerun)
        if gh_write api -X POST "repos/{owner}/{repo}/actions/runs/$us_rid/rerun-failed-jobs" >/dev/null 2>&1 || gh_write api -X POST "repos/{owner}/{repo}/actions/runs/$us_rid/rerun" >/dev/null 2>&1; then
          gh_write api -X POST "repos/{owner}/{repo}/issues/$us_pr/comments" -f body="$(unstick_rerun_note "${us_cause:-no checks on its head commit}" "$us_head")" >/dev/null 2>&1 || true
          say "Unsticking: #$us_pr stopped for ${us_cause:-no checks on its head commit}, not its code; started its CI again, once for this commit."
        else
          say "Unsticking: GitHub refused to re-run CI on #$us_pr."
        fi
        return 0 ;;
      cannot)
        say "Unsticking: #$us_pr has no CI run on its head commit and is up to date with $base, so there is nothing to re-run; a pull request's CI starts on a push to it, so its agent pushes." ;;
    esac
  done
  return 0
}

