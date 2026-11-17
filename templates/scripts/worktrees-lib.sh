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

# leftover_folders PATH_BRANCH
# Folders beside the registered worktrees that no worktree owns: no .git
# inside, and not in the list. They are what a removal that stopped on an
# installed node_modules leaves behind; git no longer lists them.
leftover_folders() {
  printf '%s\n' "$1" | tr '\\' '/' | awk -F'\t' 'NF >= 1 && $1 != "" { p = $1; sub(/\/[^\/]*$/, "", p); print p }' | sort -u | while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*/; do
      f=${f%/}
      [ -d "$f" ] || continue
      [ ! -e "$f/.git" ] || continue
      printf '%s\n' "$1" | tr '\\' '/' | awk -F'\t' -v f="$f" '$1 == f { found = 1 } END { exit !found }' || printf '%s\n' "$f"
    done
  done
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
      if (p ~ /(^|\/)[^\/]*\.stackdump$/) next
      print p
    }'
}

# pr_ends LINES KIND
# LINES is "merged<TAB>branch" or "closed<TAB>branch" per ended pull
# request. Print the branch names of KIND (merged or closed), one per line.
pr_ends() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v k="$2" '$1 == k && $2 != "" { print $2 }'
}

# unmatched_branches PATH_BRANCH ENDS OPEN_HEADS DEFAULT
# The branches of worktrees that the newest ended pull requests (ENDS, as
# pr_ends reads them) and the open ones (OPEN_HEADS, one branch per line) do
# not account for, one per line, the default branch left out. Each is one
# lookup by its own name: a pull request older than the newest thousand is
# found that way, instead of its worktree staying in the folder for good.
unmatched_branches() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v ends="$2" -v open="$3" -v def="$4" '
    BEGIN {
      n = split(ends, e, "\n"); for (i = 1; i <= n; i++) { split(e[i], kv, "\t"); if (kv[2] != "") seen[kv[2]] = 1 }
      n = split(open, o, "\n"); for (i = 1; i <= n; i++) { b = o[i]; gsub(/\r/, "", b); if (b != "") seen[b] = 1 }
    }
    NF >= 2 && $2 != "" && $2 != def && !($2 in seen) && !($2 in done) { done[$2] = 1; print $2 }'
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

# locked_worktrees PORCELAIN
# Print the paths of worktrees git shows as locked, one per line. A running
# agent's worktree is locked for as long as it works there, so it is never
# one to clear, whatever its branch looks like.
locked_worktrees() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^worktree / { path = substr($0, 10) }
    /^locked/ { if (path != "") print path }'
}

# without_paths PATH_BRANCH PATHS
# PATH_BRANCH as worktree_branches prints it, with the lines whose path is in
# PATHS (one per line) left out. Slashes are compared as forward slashes.
without_paths() {
  printf '%s\n' "$1" | awk -F'\t' -v skip="$(printf '%s\n' "$2" | tr '\\' '/')" '
    BEGIN { n = split(skip, s, "\n"); for (i = 1; i <= n; i++) { p = s[i]; gsub(/\r/, "", p); if (p != "") out[p] = 1 } }
    { p = $1; gsub(/\\/, "/", p); if (!(p in out)) print }' | sed '/^$/d'
}

# has_own_commit REFLOG_SUBJECTS
# REFLOG_SUBJECTS is a branch's reflog, one subject per line (git reflog show
# --format=%gs). True when the branch had a commit made on it. A branch only
# created, renamed or brought up to date has none, and git still calls it
# merged, so it must never count as finished work.
has_own_commit() {
  printf '%s\n' "$1" | tr -d '\r' | grep -q '^commit'
}
