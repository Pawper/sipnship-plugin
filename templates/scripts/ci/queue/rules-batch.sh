#!/bin/sh
# Pure helpers for the batch: its window, folder, order, branch, body and lines.
# Loaded by scripts/ci/batch-lib.sh; nothing here calls git or gh.

# drain_window_until NOW_EPOCH MINUTES: the end of a local drain's
# stand-down window, in UTC. The window is short and renewed each round, so
# a drain that dies holds the scheduled backstop off for one window at most.
drain_window_until() {
  dw_end=$(( $1 + ${2:-25} * 60 ))
  date -u -d "@$dw_end" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$dw_end" +%Y-%m-%dT%H:%M:%SZ
}

# stale_folder_name FOLDER STAMP: where a batch folder git no longer knows
# is moved aside (never deleted), STAMP being YYYY-MM-DD-HHMM.
stale_folder_name() { printf '%s.stale-%s\n' "$1" "$2"; }

# batch_folder_repair FOLDER STAMP: when FOLDER exists but is not a git
# checkout any more, move it aside as stale_folder_name says, print one
# line, and let git forget the worktree it was, so the next
# "git worktree add" makes it afresh. A folder left so once stopped every
# round of a night's drain with "already exists".
batch_folder_repair() {
  [ -e "$1" ] || return 0
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 && return 0
  bf_to=$(stale_folder_name "$1" "$2")
  mv "$1" "$bf_to" || return 1
  git worktree prune 2>/dev/null || true
  printf 'The batch folder %s was no longer a git checkout; moved it aside to %s and made it afresh.\n' "$1" "$bf_to"
}

# drain_stop_line TIME REASON: the last word of a drain that ended with
# green pull requests it could not batch, as the Queue tab shows it.
drain_stop_line() { printf 'The queue stopped at %s: %s.\n' "$1" "$2"; }

# deploy_refused_message REF: what the queue says when its start of the
# Deploy workflow is refused. A builder saw an agent deploy once and then
# stop with nothing changed on their side, so it names the cause and the
# handle, with the command.
deploy_refused_message() {
  printf '%s\n' "The agent is not allowed to start a deploy here, so nothing was deployed. Add the permission file with node console/cli.js permissions, or run this one command yourself: gh workflow run deploy.yml --ref ${1:-main}"
}

# batch_order ARGS...
# Print the PR numbers in the order given, one per line, with repeats
# dropped and anything that is not a number ignored.
batch_order() {
  seen=" "
  for bo_a in "$@"; do
    case "$bo_a" in ''|*[!0-9]*) continue ;; esac
    case "$seen" in *" $bo_a "*) continue ;; esac
    seen="$seen$bo_a "
    printf '%s\n' "$bo_a"
  done
}

# tests_for_diff PATHS
# PATHS is one changed path per line. Print the unit and component test
# files among them, one per line: anything under tests/ or ending in
# .test.* or .spec.* with a JavaScript or TypeScript extension. Browser
# runs (anything under e2e/, playwright/ or cypress/) are left out; the one
# full CI run covers those.
tests_for_diff() {
  printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | awk '
    /^(e2e|playwright|cypress)\// { next }
    /\/(e2e|playwright|cypress)\// { next }
    /\.(test|spec)\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/ { print; next }
    /^tests?\/.*\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/ { print }
  ' | awk '!seen[$0]++'
}

# batch_branch_name DATE [N]
# "batch-2026-10-03", or "batch-2026-10-03-2" for the second batch of a day.
batch_branch_name() {
  # DAY [N] [STAMP]: with STAMP (the time, HHMMSS) every run gets its own
  # branch, so a leftover branch from an earlier run never makes the push
  # fail as non-fast-forward.
  bb_s=${3:+-$3}
  if [ -n "$2" ] && [ "$2" -gt 1 ] 2>/dev/null; then
    printf 'batch-%s%s-%s\n' "$1" "$bb_s" "$2"
  else
    printf 'batch-%s%s\n' "$1" "$bb_s"
  fi
}

# carried_refs BODY [NUMBER]
# The lines of a pull request body the batch must carry: each issue it
# closes ("Closes #12", "Fixes #12", "Resolves #12", any case) and each spec
# it names ("Spec: specs/004-dashboard"), one per line, in the order found;
# then every line a check reads from the body (Deletes:, Mock:, Parity:,
# Twin:, Design:), whole, under a "From #NUMBER:" line when NUMBER is given.
# The lines stay whole so every check reads the batch as any body; the
# header says whose they are. A batch body without them failed spec-check
# on every src-only batch, left every member's issue open after the merge,
# and failed the delete check for a member that retires a file with its
# reason stated.
carried_refs() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v ks="${QUEUE_CARRY_KEYS:-Deletes Mock Parity Twin Design}" -v num="${2:-}" '
    BEGIN { nk = split(ks, keys, " ") }
    {
      line = $0
      while (match(tolower(line), /(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]+#[0-9]+/)) {
        m = substr(line, RSTART, RLENGTH); sub(/^[A-Za-z]+/, "", m); gsub(/[ \t]/, "", m)
        out = "Closes " m; if (!(out in seen)) { seen[out] = 1; print out }
        line = substr(line, RSTART + RLENGTH)
      }
      if (match($0, /[Ss]pec:[ \t]*[^ \t]+/)) {
        m = substr($0, RSTART, RLENGTH); sub(/^[Ss]pec:[ \t]*/, "", m)
        out = "Spec: " m; if (!(out in seen)) { seen[out] = 1; print out }
      }
      # A project escape lines ride along whole: a batch whose body
      # lacked a member "Parity:" line failed the member drift guard,
      # 23 batches in one night on one project.
      for (i = 1; i <= nk; i++) {
        if (match($0, "^[ \t]*" keys[i] ":")) {
          out = $0; sub(/^[ \t]+/, "", out); sub(/[ \t]+$/, "", out)
          if (!(out in seen)) { seen[out] = 1; esc[++ne] = out }
        }
      }
    }
    END {
      if (ne && num != "") print "From #" num ":"
      for (i = 1; i <= ne; i++) print esc[i]
    }'
}

# batch_pr_body CARRIED [REFS]
# CARRIED is one line per merged PR: "NUMBER<TAB>TITLE". REFS is what
# carried_refs gathered from every member's body. Print the body of the
# batch PR: one line per carried PR, then every member's Closes and Spec
# lines, so the batch passes spec-check whenever its members did and
# merging it closes their issues as well as the pull requests.
batch_pr_body() {
  printf '%s\n' "$BATCH_MARKER"
  printf 'One integration run for the pull requests below, merged in this order with merge commits. Each keeps its own history; the full suite runs once here.\n\n'
  printf '%s\n' "$1" | awk -F'\t' 'NF >= 1 && $1 != "" { printf "- #%s %s. Closes #%s\n", $1, $2, $1 }'
  if [ -n "$(printf '%s' "$2" | tr -d ' \n\r\t')" ]; then
    printf '\nCarried from the members:\n\n'
    printf '%s\n' "$2" | awk 'NF && !seen[$0]++'
  fi
}

# BATCH_MARKER is the first line of every batch body the queue writes. A
# batch is known by it, never by its branch name: a project branch called
# batch-escape-lines-483 was taken for a batch and closed.
BATCH_MARKER='<!-- merge-queue:batch -->'

# is_batch_body BODY
# Print "yes" when BODY is a batch the queue opened: its marker, or the
# first sentence batches opened before the marker had.
is_batch_body() {
  case "$1" in
    *"$BATCH_MARKER"*|"One integration run for the pull requests below"*) echo yes ;;
  esac
  return 0
}

# batch_line NUMBER OUTCOME [WHY]
# The one line printed per PR: "#12 merged into the batch", "#13 dropped:
# conflicts with main", "#14 merged serially".
batch_line() {
  if [ -n "$3" ]; then
    printf '#%s %s: %s\n' "$1" "$2" "$3"
  else
    printf '#%s %s\n' "$1" "$2"
  fi
}
