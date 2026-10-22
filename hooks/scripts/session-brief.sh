#!/bin/sh
# SessionStart hook: print the live state of the project in one short block
# so the agent can answer on the first turn from facts, with no tool calls.
#
# One network call (board-now.sh, one GraphQL query) covers every pull
# request and issue. Everything else is local git: the last commits, the
# branches with commits not on main, the worktrees. Reads
# .claude/session-brief.json when present for the queue log glob, the
# memory folder and the line limit. Every call fails soft: a missing or
# signed-out tool makes its section say "(unavailable)" and the hook still
# exits 0. Nothing here prints a token, a secret or an environment value.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/session-brief-lib.sh"

input=$(cat)
source=$(json_field "$input" source)
root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] && cd "$root" 2>/dev/null || exit 0

max_lines=40
queue_glob=""
memory_dir=""
timezone=""
config=".claude/session-brief.json"
if [ -f "$config" ]; then
  cfg=$(cat "$config")
  queue_glob=$(json_field "$cfg" queueLogGlob)
  memory_dir=$(json_field "$cfg" memoryDir)
  timezone=$(json_field "$cfg" timezone)
  n=$(json_number "$cfg" maxLines)
  [ -n "$n" ] && max_lines=$n
fi

# The memory folder defaults to Claude Code's own for this project,
# ~/.claude/projects/<slug>/memory, where the slug is the project path with
# every non-alphanumeric character turned into "-". A memoryDir in the
# config overrides it, for a project that keeps notes elsewhere.
if [ -z "$memory_dir" ] && [ -n "$HOME" ]; then
  native=$(pwd -W 2>/dev/null || pwd)
  memory_dir="$HOME/.claude/projects/$(project_slug "$native")/memory"
fi

sections=$(brief_sections "$source")
has() { case " $sections " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# run_bounded SECONDS COMMAND...: run with a timeout when one is available.
run_bounded() {
  rb_s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$rb_s" "$@"; else "$@"; fi
}

out="Session brief. Reply from this first. For where each issue and pull request really stands, from bodies and comments, run /project-status: readers summarize only what changed and you keep one line per item. Never run one network call per branch, worktree or issue yourself.
"
add() { out="$out$1
"; }

# The plugin's real path. $CLAUDE_PLUGIN_ROOT is set for hooks but empty in
# an agent's Bash tool, so a command written with it fails as typed; every
# plugin command an agent runs uses this path instead.
add "Plugin: $(cd "$here/../.." && pwd). In the Bash tool \$CLAUDE_PLUGIN_ROOT is empty; use this path for the plugin's scripts."

# Today, in the owner's local time. The hook runs on the owner's machine,
# so a plain date is local; gh output and runner logs are UTC, and an
# agent that dates things from them writes tomorrow's date all evening.
add "$(today_line "$(date '+%A %Y-%m-%d, %H:%M %Z')" "$timezone")"

# The API budget, one line, in a project with a GitHub remote. Reading
# rate_limit is free, and the reading is cached a minute in .scratch for
# the require-gh-budget hook and scripts/gh-budget.sh.
case "$(git remote get-url origin 2>/dev/null)" in
  *github.com*) if command -v gh >/dev/null 2>&1; then
    rl=$(run_bounded 5 sh -c '. "$1/lib.sh"; budget_read "$2"' sh "$here" "$(pwd)" 2>/dev/null || true)
    rl_line=$(budget_line "$rl" "$(date +%s)")
    [ -n "$rl_line" ] && add "Budget: $rl_line"
  fi ;;
esac

have_git=no
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then have_git=yes; fi

# Main
if has main; then
  if [ "$have_git" = yes ]; then
    log=$(git log --oneline -5 2>/dev/null)
    dirty=$(git status --porcelain 2>/dev/null | head -n 1)
    add "Main:"
    [ -n "$log" ] && add "$log"
    if [ -n "$dirty" ]; then add "The working tree has uncommitted changes."; else add "The working tree is clean."; fi
  else
    add "Main: (unavailable)"
  fi
fi

# The board, in one call.
facts=""
if has prs || has inprogress || has owner || has proposal; then
  facts=$(run_bounded 10 sh "$here/board-now.sh" 2>/dev/null) || facts=""
fi

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

# Queue
if has queue && [ -n "$queue_glob" ]; then
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
    else
      add "Queue: no run in the last two hours."
    fi
  fi
fi

# Runners, only when the workflows use self-hosted ones and none is online:
# then CI and the queue wait on a machine, not on tests. One bounded REST
# call, made only in such a project.
if grep -qs 'self-hosted' .github/workflows/*.yml 2>/dev/null && command -v gh >/dev/null 2>&1; then
  rr=$(run_bounded 5 gh api 'repos/{owner}/{repo}/actions/runners' --jq '.runners[] | [.name, .status, (.busy | tostring)] | @tsv' 2>/dev/null | tr -d '\r' || true)
  rr_total=$(printf '%s\n' "$rr" | grep -c . || true); rr_online=$(printf '%s\n' "$rr" | awk -F'\t' '$2 == "online"' | grep -c . || true)
  if [ -f scripts/ci/run-lib.sh ]; then . scripts/ci/run-lib.sh; fi
  rr_want=$(runner_count "$(cat .claude/runners.json 2>/dev/null)" 2>/dev/null || echo 3)
  if [ "${rr_total:-0}" -gt 0 ] && [ "$rr_online" = 0 ]; then
    add "Runners: none of the $rr_total self-hosted runners is online, so CI and the merge queue will wait. Start one (scripts/ci/RUNNERS.md)."
  elif [ "${rr_total:-0}" -gt 0 ] && { [ "$rr_online" -lt "$rr_total" ] || [ "$rr_total" -lt "$rr_want" ]; } && command -v runner_status >/dev/null 2>&1; then
    add "Runners: $(runner_status "$rr" "$rr_want")."
  fi
  # What the runner watch on this machine last found, if it is running.
  rw_key=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null | tr '/' '-')
  rw_state="${SIPNSHIP_HOME:-$HOME/.sipnship}/runner-watch/$rw_key.state"
  if [ -n "$rw_key" ] && [ -s "$rw_state" ]; then
    add "Runner watch: $(sed 's/^[^|]*|//' "$rw_state" | head -n 2 | paste -sd';' - | sed 's/;/; /g')."
  fi
fi
# Hosted minutes, in a private repository: a job on a hosted runner bills
# at least a minute, the allowance is per account, and one project once
# spent it all on housekeeping runs. Say what would run hosted and about
# how much, from the workflows' own schedules; nothing when none would.
if [ -d .github/workflows ] && [ -f scripts/ci/run-lib.sh ] && command -v gh >/dev/null 2>&1; then
  hm_private=$(run_bounded 5 gh api 'repos/{owner}/{repo}' --jq .private 2>/dev/null || echo "")
  if [ "$hm_private" = true ]; then
    . scripts/ci/run-lib.sh
  fi
  if [ "$hm_private" = true ] && command -v hosted_jobs >/dev/null 2>&1; then
    hm_rows=""
    for hm_f in .github/workflows/*.yml; do
      [ -f "$hm_f" ] || continue
      hm_row=$(hosted_jobs "$hm_f" "$(cat "$hm_f")")
      [ -n "$hm_row" ] && hm_rows="$hm_rows$hm_row
"
    done
    hm_line=$(hosted_estimate "$hm_rows")
    [ -n "$hm_line" ] && add "$(printf '%s' "$hm_line" | sed 's/^hosted Actions: /Hosted Actions: /'). Move them onto this project's runners (scripts/ci/RUNNERS.md), or set RUNNER_WATCH_HOSTED and QUEUE_RUNS_ON on purpose."
  fi
fi

# Deploys, only when the project's deploy path is not keeping up. One
# bounded git ls-remote for the recorded production commit; nothing when
# the project has no .claude/deploy.json.
if [ -f .claude/deploy.json ] && [ -f scripts/ci/deploy-health.sh ]; then
  dl=$(run_bounded 6 sh scripts/ci/deploy-health.sh 2>/dev/null || true)
  [ -n "$dl" ] && add "$dl"
fi
# The deploy state in one line: the queue deploys after a landing only
# when the interval has passed and no other pull request is green. --last
# reads the last Deploy run only, one REST call, no pull request scan.
if [ -f .claude/deploy.json ] && [ -f scripts/ci/deploy-gate.sh ] && command -v gh >/dev/null 2>&1; then
  dg=$(run_bounded 6 sh scripts/ci/deploy-gate.sh --last 2>/dev/null || true)
  [ -n "$dg" ] && add "Deploy: ${dg#deploy: }"
fi

# Leftover work and worktrees: local git only, one call each.
if has leftover && [ "$have_git" = yes ]; then
  default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo main)
  refs=$(git for-each-ref --format="%(refname:short)%09%(ahead-behind:$default)" refs/heads 2>/dev/null) || refs=""
  left=$(leftover_summary "$refs" 5)
  [ -n "$left" ] && add "$left"
  porcelain=$(git worktree list --porcelain 2>/dev/null)
  wt=$(worktree_summary "$porcelain")
  [ -n "$wt" ] && add "$wt"
  # The local half of the audit: worktrees with no open pull request and no
  # recent commit, and detached ones. Local git plus the facts already read.
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
      add "Of those, $stale have no open pull request and no commit in 3 days, and $detached are detached. Name them with: sh scripts/worktrees.sh audit"
    fi
  fi
fi

# Template drift: the project's copies of the plugin's scripts against the
# installed plugin. Local file comparisons only. A project that never
# refreshes them runs an old merge queue while the plugin has moved on.
if has leftover && [ -f "$here/../../templates/OWNED.txt" ] && [ -f "$here/../../scripts/sync/sync-lib.sh" ] && [ -d scripts/ci ]; then
  . "$here/../../scripts/sync/sync-lib.sh"
  t_old=0; t_missing=0
  for p in $(owned_paths "$(cat "$here/../../templates/OWNED.txt")"); do
    if [ ! -f "$p" ]; then t_missing=$((t_missing + 1))
    elif [ "$(same_text "$(cat "$p")" "$(cat "$here/../../templates/$p")")" = no ]; then t_old=$((t_old + 1)); fi
  done
  if [ $((t_old + t_missing)) -gt 0 ]; then
    add "Templates: $t_old of the plugin's scripts here differ from the installed plugin and $t_missing are missing, counting features this project does not use. See which with: sh \"$(cd "$here/../.." && pwd)/scripts/sync/sync-templates.sh\""
  fi
fi

# Screens due a comparison across platforms: a file-pair check never says
# that one platform's screen looks nothing like the other's.
if has screens && [ -f scripts/ci/parity.txt ] && [ -f "$here/../../templates/scripts/design/design-lib.sh" ]; then
  . "$here/../../templates/scripts/design/design-lib.sh"
  due=$(stale_screens "$(parity_pairs "$(cat scripts/ci/parity.txt)")" "$(cat design/screens.txt 2>/dev/null)" "$(date +%Y-%m-%d)" 14 | head -n 6 | paste -sd';' - | sed 's/;/; /g')
  [ -z "$due" ] || add "Screens not compared across platforms in 14 days: $due. After comparing: sh scripts/design/screens.sh compare NAME"
fi

# Last handoff
if has handoff && [ -n "$memory_dir" ] && [ -d "$memory_dir" ]; then
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
fi

# Proposed next, when the project runs the drive. Read-only: nothing here
# acts, and the line says so. The plan reuses the facts already fetched.
if has proposal && [ -f .claude/project-drive.json ] && [ -f "$here/../../scripts/drive/plan.sh" ]; then
  if [ -n "$facts" ]; then
    ff=$(mktemp)
    printf '%s\n' "$facts" > "$ff"
    plan=$(run_bounded 5 sh "$here/../../scripts/drive/plan.sh" --fast --facts "$ff" 2>/dev/null) || plan=""
    goals=$(printf '%s\n' "$plan" | grep -E '^[0-9]+\. ' || true)
    if [ -n "$goals" ]; then
      add "Proposed next (nothing runs until you approve; /project-drive asks):"
      add "$(trim_section "$goals" 8)"
    elif [ -n "$plan" ]; then
      add "Proposed next: $(printf '%s\n' "$plan" | grep '^stop:' | head -n 1 | sed 's/^stop: //')"
    else
      add "Proposed next: (unavailable)"
    fi
  else
    add "Proposed next: (unavailable)"
  fi
fi

trim_section "$(printf '%s' "$out")" "$max_lines"
exit 0
