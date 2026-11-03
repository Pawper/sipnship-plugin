# Sourced by session-brief.sh: the slots that read the network, each a
# function run in the background into its own file. Each call is bounded.
# Uses the hook's has, add, run_bounded and the facts it found once.

# The API budget, one line, in a project with a GitHub remote. Reading
# rate_limit is free, and the reading is cached a minute in .scratch for
# the require-gh-budget hook and scripts/gh-budget.sh.
s_budget() {
  case "$origin_url" in *github.com*) ;; *) return 0 ;; esac
  [ "$have_gh" = yes ] || return 0
  rl=$(run_bounded 5 sh -c '. "$1/lib.sh"; budget_read "$2"' sh "$here" "$(pwd)" 2>/dev/null || true)
  rl_line=$(budget_line "$rl" "$(date +%s)")
  [ -n "$rl_line" ] && add "Budget: $rl_line"
  return 0
}

# The board, in one call. The facts go to a file too, for the stale
# worktrees below and the slow lines' next read.
s_board() {
  facts=""
  if has prs || has inprogress || has owner || has proposal; then
    facts=$(run_bounded 10 sh "$here/board-now.sh" 2>/dev/null) || facts=""
  fi
  printf '%s\n' "$facts" > "$pf/facts"

  if has prs; then
    if [ -n "$facts" ]; then
      lines=$(pr_brief_lines "$facts" 10)
      if [ -n "$lines" ]; then add "Open pull requests:"; add "$lines"; fi
    else
      add "Open pull requests: (unavailable)"
    fi
  fi

  if has inprogress || has owner; then
    if [ -n "$facts" ]; then
      summary=$(issues_summary "$facts")
      [ -n "$summary" ] && add "$summary"
    else
      add "Issues: (unavailable)"
    fi
  fi

  # The allow rules are the person's to add; say so before the first deploy.
  if has owner; then
    perm=$(permissions_line .claude/settings.json)
    [ -n "$perm" ] && add "$perm"
  fi

  # Where things really stand: the saved digest, compared by last-updated
  # time with the facts just read. Local, no network. The lines come from
  # summaries readers wrote from bodies and comments.
  if has inprogress && [ -n "$facts" ] && [ -f "$here/../../scripts/board/board-lib.sh" ]; then
    . "$here/../../scripts/board/board-lib.sh"
    saved=""; [ -f .scratch/board/digest.tsv ] && saved=$(cat .scratch/board/digest.tsv)
    fresh=$(digest_freshness "$facts" "$saved")
    cur=${fresh%%	*}; tot=${fresh##*	}
    if [ "${tot:-0}" -gt 0 ]; then
      if [ -n "$saved" ]; then
        standing=$(digest_brief_lines "$facts" "$saved" 8)
        if [ -n "$standing" ]; then add "Where things stand (from the digest):"; add "$standing"; fi
      fi
      if [ "$cur" != "$tot" ]; then
        add "Status digest: $cur of $tot open items have a current summary; $((tot - cur)) changed since. Run /project-status to refresh."
      else
        add "Status digest: all $tot open items are current."
      fi
    fi
  fi

  # The local half of the audit, in the leftover section's place: worktrees
  # with no open pull request and no recent commit, and detached ones.
  # Local git plus the facts just read.
  if has leftover && [ "$have_git" = yes ]; then
    porcelain=$(git worktree list --porcelain 2>/dev/null)
    wt=$(worktree_summary "$porcelain")
    if [ -n "$wt" ]; then
      . "$here/worktree-lib.sh"
      pairs=$(printf '%s\n' "$porcelain" | tr -d '\r' | awk '
        /^worktree / { if (n > 1) print path "\t" branch; n++; path = substr($0, 10); branch = "" }
        /^branch / { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
        END { if (n > 1) print path "\t" branch }')
      heads=$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "pr" { print $6 }')
      dates=$(git for-each-ref --format='%(refname:short)%09%(committerdate:unix)' refs/heads 2>/dev/null)
      sd=$(stale_worktrees "$pairs" "$heads" "$dates" "$(date +%s)" 3)
      stale=${sd%%	*}; detached=${sd##*	}
      if [ "${stale:-0}" -gt 0 ] || [ "${detached:-0}" -gt 0 ]; then
        add "Of those, $stale have no open pull request and no commit in 3 days, and $detached are detached. Name them with: sh scripts/worktrees.sh audit" > "$pf/s13b"
      fi
    fi
  fi
  return 0
}

# Runners, only when the workflows use self-hosted ones and none is online:
# then CI and the queue wait on a machine, not on tests. Bounded REST calls,
# made only in such a project.
s_runners() {
  grep -qs 'self-hosted' .github/workflows/*.yml 2>/dev/null && [ "$have_gh" = yes ] || return 0
  rr=$(run_bounded 5 gh api 'repos/{owner}/{repo}/actions/runners' --jq '.runners[] | [.name, .status, (.busy | tostring)] | @tsv' 2>/dev/null | tr -d '\r' || true)
  # Judged from the registered runners ($rr, read once for this run) and
  # this machine's cores; the repository holds no count.
  rr_cores=$(nproc 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-0}")
  rr_line=$(brief_runner_line "$rr" "${rr_cores:-0}")
  [ -n "$rr_line" ] && add "Runners: $rr_line"
  rr_key=$(brief_runner_key_line "$(cat .claude/runners.json 2>/dev/null)")
  [ -n "$rr_key" ] && add "Runners: $rr_key"
  # The runner check leaves a "scan exclusions" line on the audit issue.
  rs_num=$(run_bounded 5 gh api 'repos/{owner}/{repo}/issues?labels=audit&state=open&per_page=1' --jq '.[0].number' 2>/dev/null || true)
  if [ -n "$rs_num" ]; then
    rs_line=$(brief_scan_line "$(run_bounded 5 gh api "repos/{owner}/{repo}/issues/$rs_num/comments?per_page=100" --jq '.[].body' 2>/dev/null || true)")
    [ -n "$rs_line" ] && add "Runners: $rs_line"
  fi
  # What the runner watch on this machine last found, if it is running.
  # Its files are named owner-repo, from the GitHub remote: no call.
  rw_key=""
  [ -z "$gh_repo" ] || rw_key="${gh_repo%%/*}-${gh_repo#*/}"
  rw_state="${SIPNSHIP_HOME:-$HOME/.sipnship}/runner-watch/$rw_key.state"
  if [ -n "$rw_key" ] && [ -s "$rw_state" ]; then
    add "Runner watch: $(sed 's/^[^|]*|//' "$rw_state" | head -n 2 | paste -sd';' - | sed 's/;/; /g')."
  fi
  return 0
}

# Hosted minutes, in a private repository: a job on a hosted runner bills
# at least a minute, the allowance is per account, and one project once
# spent it all on housekeeping runs. Say what would run hosted and about
# how much, from the workflows' own schedules; nothing when none would.
# Reading every workflow costs a few processes each, so the line is kept in
# the cache beside a checksum of the files it was read from, and read again
# only when one of them changed: the same line, without the wait.
s_hosted() {
  [ "$has_workflows" = yes ] || return 0
  hm_private=$(run_bounded 5 gh api 'repos/{owner}/{repo}' --jq .private 2>/dev/null | tr -d '\r')
  [ "$hm_private" = true ] || return 0
  hm_key=$(cksum .github/workflows/*.yml scripts/ci/run-lib.sh 2>/dev/null)
  hm_had=""; [ -f "$sb_cache/hosted.key" ] && hm_had=$(cat "$sb_cache/hosted.key")
  if [ -n "$hm_key" ] && [ "$hm_key" = "$hm_had" ] && [ -f "$sb_cache/hosted" ]; then
    hm_out=$(cached hosted)
  else
    . scripts/ci/run-lib.sh
    hm_out=""
    if command -v hosted_jobs >/dev/null 2>&1; then
      hm_rows=""
      for hm_f in .github/workflows/*.yml; do
        [ -f "$hm_f" ] || continue
        hm_row=$(hosted_jobs "$hm_f" "$(cat "$hm_f")")
        [ -n "$hm_row" ] && hm_rows="$hm_rows$hm_row
"
      done
      hm_line=$(hosted_estimate "$hm_rows")
      [ -z "$hm_line" ] || hm_out="$(printf '%s' "$hm_line" | sed 's/^hosted Actions: /Hosted Actions: /'). Move them onto this project's runners (scripts/ci/RUNNERS.md), or set QUEUE_RUNS_ON on purpose."
    fi
    if [ -n "$hm_key" ] && mkdir -p "$sb_cache" 2>/dev/null; then
      printf '%s\n' "$hm_out" > "$sb_cache/hosted.$$" && mv -f "$sb_cache/hosted.$$" "$sb_cache/hosted"
      printf '%s\n' "$hm_key" > "$sb_cache/hosted.key.$$" && mv -f "$sb_cache/hosted.key.$$" "$sb_cache/hosted.key"
    fi
  fi
  [ -n "$hm_out" ] && add "$hm_out"
  return 0
}

# A run queued over ten minutes: usually no runner is picking it up. This
# is the half of the old hosted Runner watch that a session can say; the
# nightly audit says the rest. One bounded REST call.
s_stuck() {
  [ "$has_workflows" = yes ] || return 0
  . scripts/ci/run-lib.sh
  sq_runs=$(run_bounded 5 gh api 'repos/{owner}/{repo}/actions/runs?status=queued&per_page=20' \
    --jq '.workflow_runs[] | [.id, .name, .head_branch, .status, (.created_at | fromdate)] | @tsv' 2>/dev/null || true)
  sq=$(stuck_line "$(stuck_runs "$sq_runs" "$(date +%s)" 10)")
  [ -n "$sq" ] && add "$sq"
  return 0
}

s_deploy() {
  # Deploys, only when the project's deploy path is not keeping up; nothing
  # when the project has no .claude/deploy.json. Slow (a git ls-remote and
  # a few REST calls), so read in the background and printed with its age.
  if [ -f .claude/deploy.json ] && [ -f scripts/ci/deploy-health.sh ]; then
    dl=$(with_age "$(cached deploy-health)" "$sb_age")
    [ -n "$dl" ] && add "$dl"
  fi
  # The deploy state in one line: the queue deploys after a landing only
  # when the interval has passed and no other pull request is green. --last
  # reads the last Deploy run only, one REST call, no pull request scan.
  if [ -f .claude/deploy.json ] && [ -f scripts/ci/deploy-gate.sh ] && [ "$have_gh" = yes ]; then
    dg=$(run_bounded 6 sh scripts/ci/deploy-gate.sh --last 2>/dev/null || true)
    [ -n "$dg" ] && add "Deploy: ${dg#deploy: }"
  fi
  return 0
}

s_workflows() {
  # A workflow that passed before its last change on main and has failed
  # every run since, which a template sync can cause. Slow (a REST call per
  # workflow), so read in the background by session-brief-slow.sh and
  # printed with its age.
  if has leftover && [ -f scripts/ci/workflow-breaks.sh ] && [ "$have_git" = yes ] && [ "$have_gh" = yes ]; then
    wb=$(cached workflow-breaks)
    [ -z "$wb" ] || add "Workflows ($sb_age): $wb. Open its last run; if the change was a template sync, say so on the plugin's issue."
  fi
  # Whether the live app works: one line from the latest Live run, read in the background.
  if [ -f .github/workflows/live.yml ]; then
    la=$(with_age "$(cached live-app)" "$sb_age")
    [ -n "$la" ] && add "$la"
  fi
  # The scheduled queue drain fired late or skipped by GitHub. One REST call.
  if has leftover && [ -f scripts/ci/drain-late.sh ] && [ -f .github/workflows/queue-drain.yml ] && [ "$have_gh" = yes ]; then
    dl=$(run_bounded 6 sh scripts/ci/drain-late.sh 2>/dev/null | head -n 1)
    [ -z "$dl" ] || add "$dl"
  fi
  return 0
}
