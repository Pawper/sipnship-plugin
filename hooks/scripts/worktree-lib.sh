#!/bin/sh
# Pure helpers for the end-of-task and loose-end hooks. Text in, text out;
# no git, no gh, no process calls. tests/run.sh covers each.

# dirty_non_scratch PORCELAIN [SCRATCH]
# PORCELAIN is the output of git status --porcelain. SCRATCH is the scratch
# folder, default ".scratch". Print the paths that are modified or
# untracked and are not inside the scratch folder, one per line.
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

# stray_media PATHS
# PATHS is one path per line. Print how many are images, video or build
# output, the things that belong in the work folder and never in a
# worktree. Prints 0 when there are none.
stray_media() {
  printf '%s\n' "$1" | awk '
    { l = tolower($0) }
    l ~ /\.(png|jpe?g|gif|webp|avif|tiff?|bmp|mp4|mov|webm|zip)$/ { n++; next }
    l ~ /(^|\/)(\.next|dist|build|out|coverage)\/$/ { n++ }
    END { print n + 0 }'
}

# procs_in_dir LIST DIR
# LIST is one process per line as "PID<TAB>COMMAND LINE" or
# "PID<TAB>PARENT<TAB>COMMAND LINE". Print "PID<TAB>COMMAND LINE" for the
# lines whose command line mentions DIR, with either slash and in any case,
# leaving out this plugin'\''s own hooks and the agent itself.
procs_in_dir() {
  pd=$(printf '%s' "$2" | tr '\\' '/' | tr 'A-Z' 'a-z')
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v dir="$pd" '
    NF >= 2 {
      cmd = (NF >= 3) ? $3 : $2
      c = tolower(cmd); gsub(/\\/, "/", c)
      if (index(c, dir) == 0) next
      if (c ~ /require-clean-worktree|session-brief|hooks\/scripts|get-ciminstance|claude/) next
      print $1 "\t" cmd
    }'
}

# session_procs LIST ME
# LIST is one process per line as "PID<TAB>PARENT<TAB>COMMAND LINE"; ME is
# the hook'\''s own process id. Print "PID<TAB>COMMAND LINE" for every
# process under the same session (the nearest ancestor of ME whose command
# names claude) whose command line names a script (.sh, .mjs, .js, .py,
# gradle...), leaving out ME'\''s own chain, the plugin'\''s hooks and the
# session'\''s servers. A check run as "sh scripts/ci/design-check.sh" has
# no folder in its command line, so the folder match alone never saw it;
# four of them outlived their agents one afternoon.
session_procs() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v me="$2" '
    NF >= 3 { pp[$1] = $2; cmd[$1] = $3 }
    END {
      root = ""
      for (p = me; (p in pp) && p != pp[p] && !(p in mine); p = pp[p]) {
        mine[p] = 1
        c = tolower(cmd[p]); gsub(/\\/, "/", c)
        # the claude executable, not a shell whose snapshot lives under ~/.claude
        if (root == "" && c ~ /(^|[\/"])claude(\.exe)?(["\x27 ]|$)/) root = p
      }
      if (root == "") exit
      for (p in cmd) {
        if (p in mine) continue
        c = tolower(cmd[p]); gsub(/\\/, "/", c)
        if (c ~ /hooks\/scripts|get-ciminstance|(^|[\/"])claude(\.exe)?(["\x27 ]|$)|mcp|conhost/) continue
        if (c !~ /\.(sh|bash|mjs|cjs|js|py|ts|kts)([ "\x27]|$)|gradlew|[ \/]gradle([ .]|$)/) continue
        n = 0
        for (q = pp[p]; (q in pp) && q != root && q != pp[q] && n < 200; q = pp[q]) n++
        if (q == root) print p "\t" cmd[p]
      }
    }' | sort -n
}

# pr_close_reason COMMAND
# Print "gh pr close" when the command closes a pull request with no
# comment saying why or what replaced it. Print nothing otherwise.
pr_close_reason() {
  split_commands "$1" | awk '
    {
      n = split($0, t, /[ \t]+/)
      if (t[1] != "gh" || t[2] != "pr" || t[3] != "close") next
      ok = 0
      for (i = 4; i <= n; i++) if (t[i] == "--comment" || t[i] == "-c" || t[i] ~ /^--comment=/) ok = 1
      if (!ok) { print "gh pr close"; exit }
    }'
}

# worktree_add_reason COMMAND
# Print "detached" when the command adds a worktree with a detached HEAD,
# where commits are reachable only from the folder. Print nothing otherwise.
worktree_add_reason() {
  split_commands "$1" | awk '
    {
      n = split($0, t, /[ \t]+/)
      if (t[1] != "git") next
      w = 0
      for (i = 2; i <= n; i++) {
        if (t[i] == "worktree" && t[i + 1] == "add") w = i + 1
        if (w && i > w && (t[i] == "--detach" || t[i] == "-d")) { print "detached"; exit }
      }
    }'
}

# stale_worktrees PAIRS OPEN_HEADS DATES NOW DAYS
# PAIRS is "path<TAB>branch" per worktree. OPEN_HEADS is one branch per
# line with an open pull request. DATES is "branch<TAB>epoch" of each
# branch'\''s last commit. Print how many worktrees have no open pull
# request and no commit in DAYS days, then how many are detached:
# "STALE<TAB>DETACHED".
stale_worktrees() {
  printf '%s\n' "$1" | awk -F'\t' -v heads="$2" -v dates="$3" -v now="$4" -v days="${5:-3}" '
    BEGIN {
      n = split(heads, h, "\n"); for (i = 1; i <= n; i++) if (h[i] != "") open[h[i]] = 1
      n = split(dates, d, "\n"); for (i = 1; i <= n; i++) { split(d[i], kv, "\t"); if (kv[1] != "") when[kv[1]] = kv[2] }
    }
    NF >= 1 && $1 != "" {
      if ($2 == "") { detached++; next }
      if ($2 in open) next
      if (($2 in when) && (now - when[$2]) <= days * 86400) next
      stale++
    }
    END { printf "%d\t%d\n", stale + 0, detached + 0 }'
}
# orphan_scripts LIST
# LIST as for session_procs. Print "PID<TAB>COMMAND LINE<TAB>RELATIVE PATH"
# for every process whose parent is gone (a script started with & from a
# shell that then ended; Windows keeps the dead parent'\''s id) and whose
# command line names a script by a relative path under scripts/, .scratch/,
# tests/ or status/. The caller keeps the ones whose path exists in its
# folder: ancestry cannot place an orphan, the file can.
orphan_scripts() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 3 { pp[$1] = $2; cmd[$1] = $3 }
    END {
      for (p in cmd) {
        if (pp[p] in cmd) continue
        c = cmd[p]; gsub(/\\/, "/", c)
        if (tolower(c) ~ /hooks\/scripts|get-ciminstance/) continue
        if (match(c, /(^|[ "\x27])(\.\/)?(scripts|\.scratch|tests|status)\/[^ "\x27]+\.(sh|mjs|cjs|js|py|ts|kts)([ "\x27]|$)/)) {
          r = substr(c, RSTART, RLENGTH); gsub(/^[ "\x27]+|[ "\x27]+$/, "", r); sub(/^\.\//, "", r)
          print p "\t" cmd[p] "\t" r
        }
      }
    }' | sort -n
}

