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
#
# It has 20 seconds and must finish well inside them, or nothing is printed
# and nothing is sent. Every process costs time on a busy Windows machine,
# so each section is a slot: a function run in the background into its own
# file, all side by side, each network read bounded, and the brief is the
# slots' files in order once all have ended. The lines that can only be had
# slowly (deploy health, broken workflows, stale mocks, hotspots, the
# drive's proposal) are read by session-brief-slow.sh, detached, into a
# cache the next start prints with its age.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/session-brief-lib.sh"
. "$here/session-brief-fast.sh"

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

# What every slot may read, found once.
have_git=no
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then have_git=yes; fi
have_gh=no
command -v gh >/dev/null 2>&1 && have_gh=yes
origin_url=$(git remote get-url origin 2>/dev/null | tr -d '\r')
# owner/repo from a GitHub remote, or nothing.
gh_repo=$(printf '%s' "$origin_url" | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
has_workflows=no
[ -d .github/workflows ] && [ -f scripts/ci/run-lib.sh ] && [ "$have_gh" = yes ] && has_workflows=yes
ml_file="${SIPNSHIP_HOME:-$HOME/.sipnship}/runner-watch/machine.tsv"

# The slow lines' cache, one per repository (its worktrees share it), kept
# with the machine's own SipNShip files, never in the project.
sb_common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | tr -d '\r')
case "$sb_common" in */.git) sb_common=${sb_common%/.git} ;; '') sb_common=$(pwd -W 2>/dev/null || pwd) ;; esac
sb_cache="${SIPNSHIP_HOME:-$HOME/.sipnship}/brief-cache/$(project_slug "$sb_common")"
sb_stamp=""
[ -f "$sb_cache/stamp" ] && read -r sb_stamp < "$sb_cache/stamp"
sb_now=$(date +%s)
sb_age=$(cache_age "$sb_stamp" "$sb_now")
# cached NAME: the cached text, or nothing.
cached() {
  [ -s "$sb_cache/$1" ] || return 0
  cat "$sb_cache/$1"
}

# The slots' folder. slot NAME FUNCTION runs the function in the background
# with its lines going to the file NAME; the brief joins the files in name
# order, so a slot's name is its place.
pf=$(mktemp -d 2>/dev/null) || { pf="${TMPDIR:-/tmp}/session-brief-$$"; mkdir -p "$pf" || exit 0; }
slot() { ("$2" > "$pf/$1" 2>/dev/null) </dev/null & }
add() { printf '%s\n' "$1"; }

. "$here/session-brief-network.sh"
. "$here/session-brief-local.sh"

# Every slot starts now; the board and the network reads first.
slot s04 s_board
slot s02 s_budget
slot s06 s_runners
slot s08 s_hosted
slot s09 s_stuck
slot s10 s_deploy
slot s15 s_workflows
slot s03 s_main
slot s05 s_queue
slot s07 s_waits
slot s13 s_leftover
slot s14 s_drift
slot s16 s_screens
slot s17 s_handoff
slot s18 s_plan
slot s19 s_unreleased

# The lines every brief starts with, while the slots run.
head_text="Session brief. Reply from this first. For where each issue and pull request really stands, from bodies and comments, run /project-status: readers summarize only what changed and you keep one line per item. Never run one network call per branch, worktree or issue yourself.
Plugin: $(cd "$here/../.." && pwd). In the Bash tool \$CLAUDE_PLUGIN_ROOT is empty; use this path for the plugin's scripts.
$(today_line "$(date '+%A %Y-%m-%d, %H:%M %Z')" "$timezone")"
# The plugin's real path, above: $CLAUDE_PLUGIN_ROOT is set for hooks but
# empty in an agent's Bash tool, so a command written with it fails as
# typed; every plugin command an agent runs uses this path instead. Today,
# in the owner's local time: the hook runs on the owner's machine, so a
# plain date is local; gh output and runner logs are UTC, and an agent that
# dates things from them writes tomorrow's date all evening.

wait
body=$(cat "$pf"/s* 2>/dev/null)
facts=$(cat "$pf/facts" 2>/dev/null)
# The folder this hook made above, and nothing else.
[ -n "$pf" ] && [ -d "$pf" ] && [ ! -L "$pf" ] && rm -rf "$pf"

[ -z "$body" ] || head_text="$head_text
$body"
brief=$(trim_section "$head_text" "$max_lines")
printf '%s\n' "$brief"

# The slow lines are read again in the background when the cache is over
# five minutes old and no read is running, from the board just read. The
# read is detached: its output goes nowhere, so this hook never waits on it.
sb_running=no
if [ -d "$sb_cache/lock" ]; then
  sb_lock_m=$(stat -c %Y "$sb_cache/lock" 2>/dev/null || stat -f %m "$sb_cache/lock" 2>/dev/null || echo 0)
  # A lock over five minutes old is a read that died; the next read takes it.
  [ "$(cache_due "$sb_lock_m" "$sb_now")" = yes ] || sb_running=yes
fi
if [ "$(cache_due "$sb_stamp" "$sb_now")" = yes ] && [ "$sb_running" = no ] && [ "${SIPNSHIP_BRIEF_REFRESH:-yes}" != no ] && mkdir -p "$sb_cache" 2>/dev/null; then
  [ -z "$facts" ] || printf '%s\n' "$facts" > "$sb_cache/facts.tsv"
  if command -v nohup >/dev/null 2>&1; then
    (nohup sh "$here/session-brief-slow.sh" "$sb_cache" </dev/null >/dev/null 2>&1 &)
  else
    (sh "$here/session-brief-slow.sh" "$sb_cache" </dev/null >/dev/null 2>&1 &)
  fi
fi

# The brief reaches the SipNShip dashboard, only when this machine holds a
# token for this repository (npx sipnship connect --repo). One request,
# five seconds at most, after the block above is printed. Nothing slow is
# ahead of it: the slow lines come from the cache. A failed send says one
# plain line once per session; nothing is read back.
sn_home="${SIPNSHIP_HOME:-$HOME/.sipnship}"
if [ -f "$sn_home/tokens.json" ] && command -v node >/dev/null 2>&1; then
  sn_repo=$gh_repo
  if [ -n "$sn_repo" ]; then
    sn_said=$(printf '%s' "$brief" | run_bounded 5 node "$here/../../console/brief-send.js" --session "$(json_field "$input" session_id)" --repo "$sn_repo" --machine-file "$ml_file" 2>/dev/null | head -n 1)
    [ -n "$sn_said" ] && printf '%s\n' "$sn_said"
  fi
fi
exit 0
