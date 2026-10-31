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
  gh_write api -X POST "repos/{owner}/{repo}/issues/$1/comments" -f body="$(conflict_notice "$2" "$3" "${4:-}")" >/dev/null 2>&1 || return 0
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
      printf '%s ' "$r_num"
    done
}

