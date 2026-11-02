# Sourced by session-brief.sh: the slots that read only local files and
# git, and the cached slow lines, each a function run in the background into
# its own file. Uses the hook's has, add, cached and the facts it found once.

# Main
s_main() {
  has main || return 0
  if [ "$have_git" = yes ]; then
    log=$(git log --oneline -5 2>/dev/null)
    dirty=$(git status --porcelain 2>/dev/null | head -n 1)
    add "Main:"
    [ -n "$log" ] && add "$log"
    if [ -n "$dirty" ]; then add "The working tree has uncommitted changes."; else add "The working tree is clean."; fi
  else
    add "Main: (unavailable)"
  fi
}

# Queue
s_queue() {
  has queue && [ -n "$queue_glob" ] || return 0
  newest=""; newest_m=0
  for f in $queue_glob; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$newest_m" ]; then newest_m=$m; newest=$f; fi
  done
  if [ -n "$newest" ]; then
    now=$(date +%s)
    if [ "$(log_is_recent "$newest_m" "$now")" = yes ]; then
      add "Queue: ran in the last two hours. Last line: $(tail -n 1 "$newest" 2>/dev/null)"
      # A step an agent held until another pull request landed is due: the drain named its session.
      wake=$(brief_wake_lines "$(cat "$newest" 2>/dev/null)")
      [ -z "$wake" ] || add "$wake"
    else
      add "Queue: no run in the last two hours."
    fi
  fi
  return 0
}

# Waits for a runner this week, from the queue's own log, and the machine
# line when its runners exceed one per two cores. Local files only, no
# network call; each says nothing when there is nothing to say.
s_waits() {
  wl_file=.scratch/queue/waits.tsv
  if [ ! -f "$wl_file" ] && [ -n "$sb_common" ]; then
    wl_file="$sb_common/.scratch/queue/waits.tsv"
  fi
  if [ -f "$wl_file" ]; then
    wl=$(waits_line "$(tail -n 500 "$wl_file" 2>/dev/null)" "$(date +%s)")
    [ -n "$wl" ] && add "Runners: $wl"
  fi
  if [ -f "$ml_file" ]; then
    ml=$(machine_brief_line "$(head -n 1 "$ml_file" 2>/dev/null)")
    [ -n "$ml" ] && add "Runner machine: $ml."
  fi
  return 0
}

# Leftover work and worktrees: local git only, one call each. The stale
# worktrees line after it comes from the board's slot, which has the facts.
s_leftover() {
  has leftover && [ "$have_git" = yes ] || return 0
  default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo main)
  refs=$(git for-each-ref --format="%(refname:short)%09%(ahead-behind:$default)" refs/heads 2>/dev/null) || refs=""
  left=$(leftover_summary "$refs" 5)
  [ -n "$left" ] && add "$left"
  wt=$(worktree_summary "$(git worktree list --porcelain 2>/dev/null)")
  [ -n "$wt" ] && add "$wt"
  return 0
}

# Template drift: the project's copies of the plugin's scripts against the
# installed plugin. Local file comparisons only, in one awk for every file.
# A project that never refreshes them runs an old merge queue while the
# plugin has moved on.
s_drift() {
  has leftover && [ -f "$here/../../templates/OWNED.txt" ] && [ -f "$here/../../scripts/sync/sync-lib.sh" ] && [ -d scripts/ci ] || return 0
  . "$here/../../scripts/sync/sync-lib.sh"
  t_counts=$(owned_drift "$(owned_paths "$(cat "$here/../../templates/OWNED.txt")")" "$here/../../templates")
  t_old=${t_counts%%	*}; t_missing=${t_counts##*	}
  if [ $((t_old + t_missing)) -gt 0 ]; then
    add "Templates: $t_old of the plugin's scripts here differ from the installed plugin and $t_missing are missing, counting features this project does not use. See which with: sh \"$(cd "$here/../.." && pwd)/scripts/sync/sync-templates.sh\""
  fi
  return 0
}

s_screens() {
  . "$here/session-brief-screens.sh"
  # The files over their size limit, the files several open pull requests
  # edit, and the CI jobs over their time limit: session-brief-hotspots.sh,
  # run in the background, printed with its age.
  if has leftover && [ -f scripts/ci/hotspots.txt ] && [ -f scripts/ci/hotspots-lib.sh ] && [ "$have_git" = yes ]; then
    hs_line=$(with_age "$(cached hotspots)" "$sb_age")
    [ -z "$hs_line" ] || add "$hs_line"
  fi
  return 0
}

# Last handoff
s_handoff() {
  has handoff && [ -n "$memory_dir" ] && [ -d "$memory_dir" ] || return 0
  listing=$(for f in "$memory_dir"/handoff-*; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    printf '%s\t%s\n' "$m" "$f"
  done)
  pick=$(newest_handoff "$listing")
  if [ -n "$pick" ]; then
    add "Last handoff ($(basename "$pick")):"
    add "$(handoff_head "$(cat "$pick")" 2)"
  fi
  return 0
}

# Proposed next, when the project runs the drive. Read-only: nothing here
# acts, and the line says so. The plan is slow, so session-brief-slow.sh
# makes it in the background from the board this hook read, and the brief
# prints the last one with its age.
s_plan() {
  has proposal && [ -f .claude/project-drive.json ] && [ -f "$here/../../scripts/drive/plan.sh" ] || return 0
  if [ -f "$sb_cache/plan" ]; then
    plan=$(cached plan)
    goals=$(printf '%s\n' "$plan" | grep -E '^[0-9]+\. ' || true)
    if [ -n "$goals" ]; then
      add "Proposed next ($sb_age; nothing runs until you approve; /project-drive asks):"
      add "$(trim_section "$goals" 8)"
    elif [ -n "$plan" ]; then
      add "Proposed next ($sb_age): $(printf '%s\n' "$plan" | grep '^stop:' | head -n 1 | sed 's/^stop: //')"
    else
      add "Proposed next: (unavailable)"
    fi
  else
    add "Proposed next: (being read in the background; the next session start shows it)"
  fi
  return 0
}

# Unreleased plugin work, only when there is some.
s_unreleased() {
  [ -f plugin/.claude-plugin/plugin.json ] && [ -f "$here/../../scripts/drive/drive-lib.sh" ] || return 0
  . "$here/../../scripts/drive/drive-lib.sh"
  unrel=$(plugin_unreleased_count)
  case "$unrel" in ''|0|*[!0-9]*) ;; *) add "Plugin: $unrel unreleased commit(s) on main since the last version bump." ;; esac
  return 0
}
