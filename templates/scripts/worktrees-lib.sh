#!/bin/sh
# Pure helpers for the worktree script and the merge queue. No git, no gh;
# text in, text out.

# worktree_branches PORCELAIN
# PORCELAIN is the output of git worktree list --porcelain. Print one line
# per worktree after the first (the main checkout): "path<TAB>branch". A
# detached worktree has an empty branch.
worktree_branches() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^worktree / { if (n > 1) print path "\t" branch; n++; path = substr($0, 10); branch = "" }
    /^branch / { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
    END { if (n > 1) print path "\t" branch }'
}

# worktree_for_branch PATH_BRANCH BRANCH
# Print the path of the worktree that has BRANCH checked out, or nothing.
worktree_for_branch() {
  printf '%s\n' "$1" | awk -F'\t' -v b="$2" 'NF >= 2 && $2 == b { print $1; exit }'
}

# prunable_worktrees PATH_BRANCH ENDED [ONLY_BRANCH]
# PATH_BRANCH is the output of worktree_branches. ENDED is one branch name
# per line whose work has ended (merged, or closed with its ending). Print
# the paths of worktrees whose branch is in ENDED, one per line. With
# ONLY_BRANCH, consider that branch alone. A worktree with no branch is
# never prunable here; the audit names it.
prunable_worktrees() {
  printf '%s\n' "$1" | awk -F'\t' -v merged="$2" -v only="$3" '
    BEGIN { n = split(merged, m, "\n"); for (i = 1; i <= n; i++) { b = m[i]; gsub(/^[ \t*+]+|[ \t\r]+$/, "", b); if (b != "") ok[b] = 1 } }
    NF >= 2 && $2 != "" && ($2 in ok) && (only == "" || $2 == only) { print $1 }'
}

# detached_worktrees PATH_BRANCH
# Print the paths of worktrees with no branch.
detached_worktrees() {
  printf '%s\n' "$1" | awk -F'\t' 'NF >= 1 && $1 != "" && $2 == "" { print $1 }'
}

# worktree_places PATH_BRANCH
# Print each folder that holds worktrees with how many it holds, most
# first: "312<TAB>C:/Users/me/Documents/GitHub".
worktree_places() {
  printf '%s\n' "$1" | tr '\\' '/' | awk -F'\t' '
    NF >= 1 && $1 != "" { p = $1; sub(/\/[^\/]*$/, "", p); if (p ~ /\/\.claude\/worktrees$/) p = p " (Claude Code'"'"'s, for dispatched agents)"; c[p]++ }
    END { for (p in c) printf "%d\t%s\n", c[p], p }' | sort -rn
}

# dirty_non_scratch PORCELAIN [SCRATCH]
# The same test the plugin'\''s stop hook uses: paths from git status
# --porcelain that are modified or untracked and not inside the scratch
# folder (default ".scratch"), one per line.
dirty_non_scratch() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v scratch="${2:-.scratch}" '
    length($0) > 3 {
      p = substr($0, 4)
      if (p ~ / -> /) sub(/^.* -> /, "", p)
      gsub(/^"|"$/, "", p)
      if (index(p, scratch "/") == 1 || p == scratch) next
      print p
    }'
}

# pr_ends LINES KIND
# LINES is "merged<TAB>branch" or "closed<TAB>branch" per ended pull
# request. Print the branch names of KIND (merged or closed), one per line.
pr_ends() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v k="$2" '$1 == k && $2 != "" { print $2 }'
}

# mergeable_local_branches BRANCHES MERGED PATH_BRANCH DEFAULT
# BRANCHES is one local branch per line. MERGED is the merged branch names.
# Print the local branches that are merged, are not the default branch and
# have no worktree, one per line: the ones safe to remove.
mergeable_local_branches() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v merged="$2" -v pairs="$3" -v def="$4" '
    BEGIN {
      n = split(merged, m, "\n"); for (i = 1; i <= n; i++) { b = m[i]; gsub(/^[ \t*+]+|[ \t]+$/, "", b); if (b != "") ok[b] = 1 }
      n = split(pairs, p, "\n"); for (i = 1; i <= n; i++) { split(p[i], kv, "\t"); if (kv[2] != "") held[kv[2]] = 1 }
    }
    { b = $0; gsub(/^[ \t*+]+|[ \t]+$/, "", b) }
    b != "" && b != def && (b in ok) && !(b in held) { print b }'
}
