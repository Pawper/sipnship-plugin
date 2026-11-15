#!/bin/sh
# The sanctioned way to end work and tidy worktrees. A worktree is a
# checkout, not the work: its commits live in the branch. This script
# removes a worktree only when its work has ended and the folder is clean,
# and it never loses a commit: a merged branch is on main, and a closed
# one is kept under an archive tag before its branch goes.
#
# Usage, from the main checkout:
#   sh scripts/worktrees.sh list
#       how many worktrees, in which folders, how many have ended
#   sh scripts/worktrees.sh audit [--days 3]
#       name the worktrees that are detached, whose pull request merged or
#       closed, or that have no open pull request and no commit in N days
#   sh scripts/worktrees.sh prune [--apply] [--closed] [--branches] [--branch NAME]
#       remove the clean worktrees of merged branches and their local
#       branches; with --closed also those of closed pull requests, after
#       tagging each branch as closed/NAME; with --branches also merged
#       local branches that have no worktree. Prints only, unless --apply.
#   sh scripts/worktrees.sh close PR "why, or what replaced it"
#       give a pull request its ending: comment, close, tag the branch as
#       closed/NAME, remove its worktree and its local branch.
#
# A worktree with uncommitted files outside .scratch/ is never removed; it
# is listed as skipped. On Windows, long paths are turned on and a linked
# node_modules is unlinked first, the two things that make removal fail.
set -e
# Never stop without a word: set -e ends the script at the first failing
# command, and a close once exited 1 with nothing printed.
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "worktrees.sh ${cmd:-} stopped with exit $rc at: ${step:-start}" >&2' EXIT
here=$(dirname "$0")
. "$here/worktrees-lib.sh"

cmd=${1:-list}
shift 2>/dev/null || true
apply=no; only=""; closed=no; branches=no; days=3; pr=""; reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=yes ;;
    --closed) closed=yes ;;
    --branches) branches=yes ;;
    --branch) shift; only=$1 ;;
    --days) shift; days=$1 ;;
    *) if [ -z "$pr" ]; then pr=$1; else reason=$1; fi ;;
  esac
  shift
done

default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo main)
default_local=${default#origin/}
step="listing worktrees"
porcelain=$(git worktree list --porcelain)
pairs=$(worktree_branches "$porcelain")
count=$(printf '%s\n' "$pairs" | sed '/^$/d' | wc -l | tr -d ' ')
# A locked worktree (a running agent's) and the one this script runs in are never cleared or named.
own=$(git rev-parse --show-toplevel 2>/dev/null || true)
pairs=$(without_paths "$pairs" "$(locked_worktrees "$porcelain")
$own")

# One call for every ended pull request: merged or closed, with its branch.
ends=""
if command -v gh >/dev/null 2>&1; then
  # REST, ten pages of a hundred (the newest thousand ended pull requests): gh pr list would spend GraphQL points.
  for p in 1 2 3 4 5 6 7 8 9 10; do
    page=$(gh api "repos/{owner}/{repo}/pulls?state=closed&per_page=100&page=$p" \
      --jq '.[] | [(if .merged_at then "merged" else "closed" end), .head.ref] | @tsv' 2>/dev/null || true)
    [ -n "$page" ] || break
    ends="$ends
$page"
  done
  ends=$(printf '%s\n' "$ends" | sed '/^$/d')
  # A worktree whose branch no ended or open pull request above accounts for may belong to one older than
  # the newest thousand: ask for it by its branch, one REST call each (a branch with no pull request ends nothing).
  case "$cmd" in
    audit|prune)
      step="looking up older pull requests by branch"
      open_all=$(gh api --paginate "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[].head.ref' 2>/dev/null || true)
      for b in $(unmatched_branches "$pairs" "$ends" "$open_all" "$default_local"); do
        one=$(gh api "repos/{owner}/{repo}/pulls?state=all&head={owner}:$b&per_page=1" \
          --jq '.[] | select(.state == "closed") | [(if .merged_at then "merged" else "closed" end), .head.ref] | @tsv' 2>/dev/null || true)
        [ -z "$one" ] || ends="$ends
$one"
      done
      ends=$(printf '%s\n' "$ends" | sed '/^$/d') ;;
  esac
fi
# Merged means: its pull request merged, or git says it is merged AND the
# branch has had commits of its own. Git also calls a branch "merged" when
# it was just created and has no work yet, and a fresh worktree must never
# be pruned, so a branch with nothing in its history beyond its creation
# does not count.
step="reading which branches merged"
gh_merged=$(pr_ends "$ends" merged)
git_merged=$(git branch --merged "$default" --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
  [ -n "$b" ] || continue
  case "
$gh_merged
" in *"
$b
"*) continue ;; esac
  if has_own_commit "$(git reflog show --format=%gs "refs/heads/$b" 2>/dev/null)"; then printf '%s\n' "$b"; fi
done)
merged="$gh_merged
$git_merged"
closed_heads=$(pr_ends "$ends" closed)

# remove_one PATH: the Windows-safe removal. Returns non-zero when git
# would not remove it.
remove_one() {
  git config core.longpaths true 2>/dev/null || true
  if [ -L "$1/node_modules" ]; then
    if [ -n "$WINDIR" ]; then cmd //c rmdir "$(cd "$1" && pwd -W 2>/dev/null | tr '/' '\\')\\node_modules" >/dev/null 2>&1 || true
    else unlink "$1/node_modules" 2>/dev/null || true; fi
  elif [ -d "$1/node_modules" ] && [ -n "$WINDIR" ]; then
    # An installed node_modules (pnpm's junctions and deep paths) is what made git stop with "Directory not empty",
    # leaving the folder behind with its worktree already gone from the list: cmd's rmdir clears it, never following a junction.
    cmd //c rmdir /s /q "$(cd "$1" && pwd -W 2>/dev/null | tr '/' '\\')\\node_modules" >/dev/null 2>&1 || true
  fi
  # git's own reason is kept for the message: "would not remove it" alone left a backlog unexplained.
  remove_why=$(git worktree remove "$1" 2>&1) || return 1
}

# is_clean PATH: nothing uncommitted outside the scratch folder.
is_clean() { [ -z "$(dirty_non_scratch "$(git -C "$1" status --porcelain 2>/dev/null)")" ]; }

# drop_branch NAME KIND: remove a local branch whose work has ended. A
# closed one is tagged first so its commits stay reachable.
drop_branch() {
  [ -n "$1" ] && [ "$1" != "$default_local" ] || return 0
  git show-ref --verify --quiet "refs/heads/$1" || return 0
  if [ "$2" = closed ]; then
    if git tag -f "closed/$1" "refs/heads/$1" >/dev/null 2>&1; then echo "kept the commits of $1 as tag closed/$1"
    else echo "could not tag $1 as closed/$1; its branch is kept"; return 0; fi
    if git branch -D "$1" >/dev/null 2>&1; then echo "removed local branch $1"
    else echo "could not remove local branch $1 (a worktree may still hold it); run prune later"; fi
  else
    # A branch git will not delete (a lock, a worktree still holding it) is said and the run goes on: under set -e a failed delete ended the whole prune, leaving the rest of the list untouched.
    if git branch -d "$1" >/dev/null 2>&1 || git branch -D "$1" >/dev/null 2>&1; then echo "removed local branch $1 (merged)"
    else echo "could not remove local branch $1; run prune later"; fi
  fi
}

prune_set() { # KIND(merged|closed) HEADS
  prunable=$(prunable_worktrees "$pairs" "$2" "$only")
  printf '%s\n' "$prunable" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    branch=$(printf '%s\n' "$pairs" | awk -F'\t' -v p="$path" '$1 == p { print $2; exit }')
    if ! is_clean "$path"; then echo "skipped $path: it has uncommitted files outside .scratch/"; continue; fi
    if [ "$apply" = yes ]; then
      if remove_one "$path"; then echo "removed $path"; drop_branch "$branch" "$1"
      else echo "skipped $path: git would not remove it ($(printf '%s' "$remove_why" | tr '\n' ' ' | cut -c1-160))"; fi
    else
      echo "would remove $path and its local branch $branch ($1)"
    fi
  done
}

case "$cmd" in
  list)
    m=$(prunable_worktrees "$pairs" "$merged" | sed '/^$/d' | wc -l | tr -d ' ')
    c=$(prunable_worktrees "$pairs" "$closed_heads" | sed '/^$/d' | wc -l | tr -d ' ')
    d=$(detached_worktrees "$pairs" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "$count worktrees besides the main checkout: $m of merged branches, $c of closed pull requests, $d detached."
    worktree_places "$pairs" | awk -F'\t' '{ printf "  %s in %s\n", $1, $2 }'
    [ $((m + c + d)) -eq 0 ] || echo "Run: sh scripts/worktrees.sh audit   to name them, then prune."
    exit 0
    ;;
  audit)
    now=$(date +%s)
    open_heads=""
    command -v gh >/dev/null 2>&1 && open_heads=$(gh api --paginate "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[].head.ref' 2>/dev/null || true)
    dates=$(git for-each-ref --format='%(refname:short)%09%(committerdate:unix)' refs/heads 2>/dev/null)
    found=0
    for p in $(detached_worktrees "$pairs"); do echo "detached: $p (commits here are on no branch; make one with git -C PATH switch -c NAME)"; found=1; done
    prunable_worktrees "$pairs" "$merged" | sed '/^$/d' | sed 's/^/merged: /'
    prunable_worktrees "$pairs" "$closed_heads" | sed '/^$/d' | sed 's/^/closed: /'
    printf '%s\n' "$pairs" | awk -F'\t' -v heads="$open_heads" -v dates="$dates" -v now="$now" -v days="$days" -v ended="$merged
$closed_heads" '
      BEGIN {
        n = split(heads, h, "\n"); for (i = 1; i <= n; i++) if (h[i] != "") open[h[i]] = 1
        n = split(dates, d, "\n"); for (i = 1; i <= n; i++) { split(d[i], kv, "\t"); if (kv[1] != "") when[kv[1]] = kv[2] }
        n = split(ended, e, "\n"); for (i = 1; i <= n; i++) { b = e[i]; gsub(/^[ \t*+]+|[ \t]+$/, "", b); if (b != "") done[b] = 1 }
      }
      NF >= 2 && $2 != "" && !($2 in open) && !($2 in done) && (($2 in when) && (now - when[$2]) > days * 86400) {
        printf "stale: %s (%s, no open pull request, no commit in %d days)\n", $1, $2, days
      }'
    exit 0
    ;;
  prune)
    prune_set merged "$merged"
    [ "$closed" = yes ] && prune_set closed "$closed_heads"
    if [ "$branches" = yes ]; then
      all=$(git branch --format='%(refname:short)')
      pairs_now=$(worktree_branches "$(git worktree list --porcelain)")
      mergeable_local_branches "$all" "$merged" "$pairs_now" "$default_local" | while IFS= read -r b; do
        [ -n "$b" ] || continue
        if [ "$apply" = yes ]; then drop_branch "$b" merged; else echo "would remove local branch $b (merged)"; fi
      done
    fi
    if [ "$apply" = yes ]; then git worktree prune; echo "Done."; else echo "Nothing was removed; add --apply to do it."; fi
    ;;
  close)
    [ -n "$pr" ] && [ -n "$reason" ] || { echo 'Usage: sh scripts/worktrees.sh close PR "why, or what replaced it"' >&2; exit 2; }
    step="reading pull request $pr"
    info=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '[.head.ref, .state, (.merged | tostring)] | @tsv' 2>/dev/null || true)
    [ -n "$info" ] || { echo "Could not read pull request $pr from GitHub." >&2; exit 1; }
    branch=$(printf '%s' "$info" | cut -f1); state=$(printf '%s' "$info" | cut -f2); merged_pr=$(printf '%s' "$info" | cut -f3)
    step="finding its worktree"
    path=$(worktree_for_branch "$pairs" "$branch")
    if [ -n "$path" ] && ! is_clean "$path"; then
      echo "Not closing: the worktree at $path has uncommitted files outside .scratch/. Commit them or move them aside first." >&2
      exit 1
    fi
    step="commenting and closing $pr"
    # Already closed by hand (or merged): say so, record the reason, and
    # still give it its ending: tag the branch and remove the worktree.
    gh api -X POST "repos/{owner}/{repo}/issues/$pr/comments" -f body="$reason" >/dev/null 2>&1 || echo "could not comment on $pr; the reason is not recorded there"
    if [ "$merged_pr" = true ]; then
      echo "pull request $pr is already merged; added the reason, tidying its worktree and branch"
    elif [ "$state" = closed ]; then
      echo "pull request $pr was already closed; added the reason, tidying its worktree and branch"
    else
      gh api -X PATCH "repos/{owner}/{repo}/pulls/$pr" -f state=closed >/dev/null
      echo "closed pull request $pr with its reason"
    fi
    step="removing its worktree and branch"
    if [ -n "$path" ]; then remove_one "$path" && echo "removed $path" || echo "could not remove $path; run prune later"; fi
    if [ "$merged_pr" = true ]; then drop_branch "$branch" merged; else drop_branch "$branch" closed; fi
    ;;
  *)
    echo 'Usage: sh scripts/worktrees.sh list | audit [--days N] | prune [--apply] [--closed] [--branches] [--branch NAME] | close PR "reason"' >&2
    exit 2
    ;;
esac
