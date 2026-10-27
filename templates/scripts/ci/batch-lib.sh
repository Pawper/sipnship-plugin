#!/bin/sh
# Pure helpers for the merge queue's batch mode. Nothing here calls git or
# gh, so every function is tested with strings in tests/run.sh.

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

# carried_refs BODY
# The lines of a pull request body the batch must carry: each issue it
# closes ("Closes #12", "Fixes #12", "Resolves #12", any case) and each spec
# it names ("Spec: specs/004-dashboard"), one per line, in the order found.
# A batch body without them failed spec-check on every src-only batch and
# left every member's issue open after the merge.
carried_refs() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v ks="${QUEUE_CARRY_KEYS:-Parity Twin Design}" '
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
          if (!(out in seen)) { seen[out] = 1; print out }
        }
      }
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

# drain_candidates LIST BASE [TRIED]
# LIST is one open pull request per line:
#   "NUMBER<TAB>DRAFT(true|false)<TAB>MERGEABLE<TAB>ROLLUP<TAB>BASE_BRANCH"
# where ROLLUP is green, red, pending or none. Print, one per line in
# number order, the pull requests the drain should merge this round: not a
# draft, aimed at BASE, not conflicting, green, and not in TRIED (numbers a
# previous round already tried and could not merge).
drain_candidates() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && toupper($3) != "CONFLICTING" && $4 == "green" && index(tried, " " $1 " ") == 0 { print $1 }' | sort -n
}

# drain_waiting LIST BASE
# How many non-draft pull requests aimed at BASE are still running CI.
drain_waiting() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && ($4 == "pending" || $4 == "cancelled") { n++ } END { print n + 0 }'
}

# drain_retry LIST BASE RETRIED
# The red pull requests (not drafts, aimed at BASE) whose failed run has
# not been re-run yet in this drain: one retry each, because a flaky test
# or a lost runner should not stop a change.
drain_retry() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && (($4 == "red" && index(tried, " " $1 " ") == 0) || $4 == "cancelled") { print $1 }' | sort -n
}

# drain_attention LIST BASE RETRIED
# The pull requests a person or an agent must look at, one per line as
# "NUMBER<TAB>why": conflicting with the base, or red again after its one
# retry. The drain exits non-zero naming these, so nobody has to notice.
drain_attention() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base {
      if (toupper($3) == "CONFLICTING") printf "%s\thas conflicts with %s\n", $1, base
      else if ($4 == "red" && index(tried, " " $1 " ") > 0) printf "%s\tfailed CI twice\n", $1

    }' | sort -n
}

# rest_rollup WORDS
# WORDS is one check-run outcome per line as REST reports it: a conclusion
# (success, failure, neutral, cancelled, timed_out, action_required,
# skipped, stale) or, while the run is not complete, its status (queued,
# in_progress, waiting, pending). Print the one word the drain reads:
# none, red, pending, cancelled or green. A cancelled job is not a red one:
# a runner hiccup or a newer push cancels it, and the drain re-runs it
# once rather than calling the change broken.
rest_rollup() {
  printf '%s\n' "$1" | tr -d '\r' | tr 'A-Z' 'a-z' | awk '
    NF == 0 { next }
    { n++ }
    /failure|timed_out|action_required|startup_failure/ { red = 1 }
    /cancelled/ { canc = 1 }
    /queued|in_progress|waiting|pending|requested/ { pend = 1 }
    END { if (n == 0) print "none"; else if (red) print "red"; else if (pend) print "pending"; else if (canc) print "cancelled"; else print "green" }'
}

# required_check LINES [NAME]
# LINES is "name<TAB>status<TAB>conclusion" per check run on one commit.
# Print the state of the check branch protection requires (NAME, default
# "CI passed") on that commit: passed, failed, pending, or missing when it
# has not reported. GitHub refuses a merge until it has passed on the head
# commit, whatever else is green: "Required status check CI passed is
# expected" stopped batches three times while the queue watched the
# workflow run instead of the check.
required_check() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v want="${2:-CI passed}" '
    $1 == want { found = 1; st = tolower($2); c = tolower($3)
      if (st != "completed") state = "pending"
      else if (c == "success" || c == "neutral" || c == "skipped") state = "passed"
      else state = "failed" }
    END { print found ? state : "missing" }'
}

# rest_rollup_named LINES [SUMMARY]
# LINES is "name<TAB>outcome" per check run. The summary check (SUMMARY,
# default "CI passed") fails whenever a job it waits on was cancelled, so a
# job cancelled before any runner took it read as a red pull request and
# was set aside as "failed CI twice". When another check was cancelled, the
# summary's failure is left out, and the rollup is cancelled, which the
# drain re-runs and waits on.
rest_rollup_named() {
  rrn=$(printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v sum="${2:-CI passed}" '
    NF >= 2 { name[NR] = $1; out[NR] = tolower($2); if (out[NR] ~ /cancelled/ && $1 != sum) canc = 1; n = NR }
    END { for (i = 1; i <= n; i++) { if (canc && name[i] == sum && out[i] ~ /failure/) continue; print out[i] } }')
  rest_rollup "$rrn"
}

# mergeable_word STATE
# STATE is REST's mergeable_state: clean, unstable, has_hooks, behind,
# blocked, dirty, draft, unknown. Print the word the drain reads:
# CONFLICTING for dirty, UNKNOWN for unknown or empty, MERGEABLE otherwise.
mergeable_word() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    dirty) echo CONFLICTING ;;
    ''|unknown) echo UNKNOWN ;;
    *) echo MERGEABLE ;;
  esac
}

# drain_hold GREEN WAITING
# Print "yes" when the drain should wait before merging: one green pull
# request would merge serially while WAITING others are still
# running CI, and a serial merge moves main under every one of them, so
# they are updated and sent back round CI and the batch that follows has
# nothing. Hold until they finish, then batch. Print "no" when nothing is
# waiting, nothing is green, or there are enough green ones to batch now.
drain_hold() {
  if [ "${1:-0}" -eq 1 ] && [ "${2:-0}" -gt 0 ]; then echo yes; else echo no; fi
}

# rate_wait RATE NOW [FLOOR]
# RATE is "remaining<TAB>reset_epoch" as gh api rate_limit reports it for
# the core API. Print the seconds the queue should wait before spending
# more calls: 0 when more than FLOOR (default 500) calls are left, when the
# window has already reset, or when RATE is empty (the budget could not be
# read, and the queue goes on rather than stall); otherwise the seconds
# until the reset, at least one.
rate_wait() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v floor="${3:-500}" '
    NR == 1 {
      rem = $1 + 0; reset = $2 + 0
      if ($1 == "" || rem > floor || reset <= now) { print 0; exit }
      w = reset - now; if (w < 1) w = 1; print w; exit
    }
    END { if (NR == 0) print 0 }'
}

# rate_limit_hit TEXT
# Print "yes" when TEXT, the error output of a gh call, says GitHub's API
# rate limit was exceeded, "no" otherwise.
rate_limit_hit() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    *"rate limit exceeded"*|*"api rate limit"*|*"secondary rate limit"*) echo yes ;;
    *) echo no ;;
  esac
}

# queue_lock_reason LOCK NOW ALIVE [STALE_SECONDS]
# LOCK is the text of the queue's lock file: "pid<TAB>started_epoch<TAB>mode".
# ALIVE is yes when that pid is still running. Print why a second queue must
# not start ("a --drain started 12 minutes ago is still running (pid 4242)"),
# or nothing when LOCK is empty, its process is gone, or it is older than
# STALE_SECONDS (default three hours), which is a lock a crash left behind.
queue_lock_reason() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v alive="$3" -v stale="${4:-10800}" '
    NR == 1 && NF >= 3 && $1 != "" {
      age = now - ($2 + 0)
      if (alive != "yes" || age > stale) exit
      printf "a %s started %d minute(s) ago is still running (pid %s)\n", $3, int(age / 60), $1
      exit
    }'
}

# nearest_root FILE ROOTS
# ROOTS is one folder per line, each holding a package.json or tsconfig.json
# ("." for the repository root). Print the deepest root that contains FILE,
# so a test in web/src/a.test.ts runs from web/ when web/package.json exists,
# and from "." otherwise. Print nothing when no root contains it.
nearest_root() {
  nr_f=$(printf '%s' "$1" | tr '\\' '/')
  printf '%s\n' "$2" | tr -d '\r' | tr '\\' '/' | awk -v f="$nr_f" '
    { r = $0; sub(/\/$/, "", r); if (r == "" ) next
      if (r == ".") { if (length(best) == 0 && !seen) { best = "."; seen = 1 }; next }
      if (substr(f, 1, length(r) + 1) == r "/" && length(r) > length(best)) { best = r; seen = 1 } }
    END { if (seen) print best }'
}

# serial_refusal READY BECAUSE
# READY is the other open pull requests that are green and do not conflict
# with main, space separated; BECAUSE is the reason given with --because.
# Print why a serial merge is refused, or nothing when it may go: alone is
# fine when nothing else is ready, and a named reason always is. One agent
# hard-coded --serial into a landing script and copied it for every pull
# request; five that were ready together each landed alone, with a full CI
# run and a deploy apiece.
serial_refusal() {
  [ -z "$(printf '%s' "$2" | tr -d ' ')" ] || return 0
  [ -n "$(printf '%s' "$1" | tr -d ' ')" ] || return 0
  sr_n=$(printf '%s\n' $1 | wc -l | tr -d ' ')
  sr_list=$(printf '#%s ' $1 | sed 's/ $//')
  echo "$sr_n other green pull request(s) are ready to land with it ($sr_list); merge them together with --drain (or --batch), or give the reason this one must land alone: --serial N --because migration|conflict|must-land-alone|\"why\""
}

# serial_title TITLE NUMBER REASON
# The squash commit title of a serial merge, carrying its reason, so the
# nightly audit can read main's history: "Fix the chime (#79) [serial: alone]".
serial_title() {
  printf '%s (#%s) [serial: %s]\n' "$1" "$2" "${3:-alone}"
}

# serial_bursts LINES [WINDOW_SECONDS] [MAX]
# LINES is main's recent first-parent history, "epoch<TAB>subject", one per
# line. Print one line when more than MAX (default 2) serial merges landed
# within WINDOW (default an hour): how many, their reasons, and what to do.
# Nothing otherwise.
serial_bursts() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v win="${2:-3600}" -v max="${3:-2}" '
    $2 ~ /\[serial: [^]]*\]/ {
      r = $2; sub(/.*\[serial: /, "", r); sub(/\].*/, "", r)
      t[++n] = $1 + 0; why[n] = r
    }
    END {
      # times arrive newest first from git log; sort ascending
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (t[j] < t[i]) { x = t[i]; t[i] = t[j]; t[j] = x; y = why[i]; why[i] = why[j]; why[j] = y }
      best = 0
      for (i = 1; i <= n; i++) { k = 0; for (j = i; j <= n && t[j] - t[i] <= win; j++) k++; if (k > best) { best = k; bi = i } }
      if (best <= max) exit
      rs = ""; for (j = bi; j < bi + best; j++) rs = rs (rs == "" ? "" : ", ") why[j]
      printf "Main took %d serial merges within an hour (reasons: %s). Pull requests that are ready together should land as one batch: sh scripts/ci/merge-queue.sh --drain.\n", best, rs
    }'
}

# conflict_line FILES
# FILES is the conflicting paths from git merge-tree, one per line. Print
# the one line a serial run says for a pull request that conflicts with
# main, instead of "updated" round after round.
conflict_line() {
  cl=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n 5 | tr '\n' ' ' | sed 's/ $//')
  cl_gen=""; [ "$2" = generated ] && cl_gen="; generated only: a rebuild on the batch would resolve this"
  if [ -n "$cl" ]; then echo "conflicts with main in $cl$cl_gen; resolve it on the branch, then queue it again"
  else echo "conflicts with main$cl_gen; resolve it on the branch, then queue it again"; fi
}

# batch_members BODY
# The member pull requests a batch pull request's body lists, one number
# per line, from its "- #N title. Closes #N" lines.
batch_members() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^- #\([0-9][0-9]*\) .*/\1/p'
}

# drop_members LIST MEMBERS
# LIST is the drain's rows, "NUMBER<TAB>...". Print LIST without the rows
# whose number is in MEMBERS (space or line separated). A member of an
# open batch belongs to that batch: the drain once merged two members on
# their own while their batch ran CI, then sent the batch round again.
drop_members() {
  printf '%s\n' "$1" | awk -F'\t' -v m=" $(printf '%s' "$2" | tr '\n' ' ') " 'NF && index(m, " " $1 " ") == 0'
}

# queue_eta QUEUED BUSY RUNNERS [AVG_MINUTES]
# One line on a run that waits on machines rather than tests: how many
# jobs are queued, how many runners are busy, and a rough time to clear
# the queue (each runner runs one job at a time; AVG_MINUTES per job,
# default 4). Nothing when no job is queued.
queue_eta() {
  [ "${1:-0}" -gt 0 ] 2>/dev/null || return 0
  qe_r=${3:-0}; [ "$qe_r" -gt 0 ] 2>/dev/null || qe_r=0
  if [ "$qe_r" -eq 0 ]; then printf '%s job(s) queued and no runner online.\n' "$1"; return 0; fi
  qe_eta=$(( ($1 + qe_r - 1) / qe_r * ${4:-4} ))
  printf '%s job(s) queued, %s of %s runner(s) busy; about %s minute(s) at one job per runner. Waiting on machines, not on a failure.\n' "$1" "${2:-0}" "$qe_r" "$qe_eta"
}

# anchored_group ORDER PAIRS
# ORDER is the batch's pull requests, earliest first, space separated.
# PAIRS is one conflicting pair per line, "A B". Print the batch: the
# first pull request always, then the largest set of the others that
# conflicts with nothing in it, earliest first on a tie. Merging in order
# and dropping each conflict kept {251, 252} and left 253 and 254 out when
# 253 and 254 conflicted only with 252; this keeps {251, 253, 254}.
# Exhaustive up to 16 pull requests, in order after that.
anchored_group() {
  printf '%s\n' "$2" | awk -v order="$1" '
    NF == 2 { c[$1 " " $2] = 1; c[$2 " " $1] = 1 }
    END {
      n = split(order, p, " ")
      if (n == 0) exit
      if (n > 17) {
        k = 0
        for (i = 1; i <= n; i++) { ok = 1; for (j = 1; j <= k; j++) if ((p[i] " " g[j]) in c) ok = 0; if (ok) g[++k] = p[i] }
        for (j = 1; j <= k; j++) print g[j]
        exit
      }
      best = -1; bestkey = ""
      m = n - 1; total = 2 ^ m
      for (mask = 0; mask < total; mask++) {
        k = 1; s[1] = p[1]; ok = 1; key = ""
        for (b = 0; b < m && ok; b++) {
          if (int(mask / 2 ^ b) % 2 == 0) continue
          x = p[b + 2]
          for (j = 1; j <= k; j++) if ((x " " s[j]) in c) { ok = 0; break }
          s[++k] = x
        }
        if (!ok) continue
        # earlier first on a tie: the key reads the chosen positions in order
        for (b = 0; b < m; b++) key = key (int(mask / 2 ^ b) % 2 ? "1" : "0")
        if (k > best || (k == best && key > bestkey)) { best = k; bestkey = key; for (j = 1; j <= k; j++) out[j] = s[j] }
      }
      for (j = 1; j <= best; j++) print out[j]
    }'
}

# conflict_notice FILES WITH
# The comment the queue leaves on a pull request it could not merge for a
# conflict: which files, with what, and what to do. WITH is "main" or a
# pull request number. The owning agent finds it on its next session.
conflict_notice() {
  cn_files=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n 10 | sed 's/^/- `/; s/$/`/')
  if [ "$2" = main ]; then cn_with="main"; else cn_with="#$2, which goes into this batch first"; fi
  printf 'The merge queue could not take this pull request: it conflicts with %s' "$cn_with"
  if [ -n "$cn_files" ]; then printf ' in:\n\n%s\n\n' "$cn_files"; else printf '.\n\n'; fi
  if [ "$3" = generated ]; then printf 'Every file here is generated build output (scripts/ci/generated-paths.txt): a rebuild on the batch would resolve this, and the queue does that itself when the list names a rebuild: command.\n\n'; fi
  printf 'To resolve it: in this branch'"'"'s worktree, merge main in (`git fetch origin && git merge origin/main`), fix the files, run their tests, and push. Never rebase or force-push. The queue takes it again once it is green. It is labeled state:blocked until then.\n'
}

# held_reason LABELS BODY
# LABELS is a pull request's label names, one per line. Print why it is
# held when it carries the label "queue:hold" or "hold", or a line
# "Queue: hold" in its body; nothing otherwise. A held pull request is
# green but not to be merged yet: the drain landed one under a batch in
# progress, and batched two that were meant to land one at a time.
held_reason() {
  if printf '%s\n' "$1" | tr -d '\r' | grep -qixE 'queue:hold|hold'; then echo "held by its label"; return 0; fi
  if printf '%s\n' "$2" | tr -d '\r' | grep -qiE '^[[:space:]]*queue:[[:space:]]*hold'; then echo 'held by its "Queue: hold" line'; fi
  return 0
}

# pause_until NOW SPEC
# NOW in epoch seconds, SPEC a length: "2h", "45m", or bare minutes "90".
# Print the epoch the pause ends; nothing for a SPEC it cannot read.
pause_until() {
  case "$2" in
    *[hH]) pu_n=${2%[hH]}; pu_m=60 ;;
    *[mM]) pu_n=${2%[mM]}; pu_m=1 ;;
    *) pu_n=$2; pu_m=1 ;;
  esac
  case "$pu_n" in ''|*[!0-9]*) return 0 ;; esac
  echo $(( $1 + pu_n * pu_m * 60 ))
}

# release_workflows DEPLOY_JSON: the release workflows listed under
# "releases" in .claude/deploy.json, one a line (also in sync-lib.sh).
release_workflows() {
  printf '%s' "$1" | tr -d '\r\n' | sed -n 's/.*"releases"[ \t]*:[ \t]*\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | sed 's/[" \t]//g; /^$/d'
}

# queue_status LOCK_REASON LAST_LINE
# One line for --status: "running: a --drain started 12 minute(s) ago is
# still running (pid 4242); last line: ..." or "idle; last line: ...".
# LOCK_REASON is queue_lock_reason'\''s output, empty when no live queue
# holds the lock.
queue_status() {
  if [ -n "$1" ]; then printf 'running: %s' "$1"; else printf 'idle'; fi
  if [ -n "$2" ]; then printf '; last line: %s\n' "$2"; else printf '\n'; fi
}

# deploy_gate GREEN LAST_EPOCH NOW INTERVAL_MIN
# Why a deploy is held, or nothing when one is due: "N green PR(s)
# waiting" while another open pull request is green (it lands first, and
# one deploy carries both), or "last deploy M minutes ago, interval I" while
# the interval from .claude/deploy.json has not passed. LAST_EPOCH is empty
# when no deploy is recorded.
deploy_gate() {
  if [ "${1:-0}" -gt 0 ]; then
    if [ "$1" -eq 1 ]; then echo "1 green PR waiting"; else echo "$1 green PRs waiting"; fi
    return 0
  fi
  if [ -n "$2" ] && [ $(( $3 - $2 )) -lt $(( $4 * 60 )) ]; then
    echo "last deploy $(( ($3 - $2) / 60 )) minutes ago, interval $4"
  fi
}

# held_note N
# The line for N green pull requests on hold, which the gate does not wait
# for because a drain never lands them; nothing when N is 0.
held_note() {
  case "$1" in
    ''|0) ;;
    1) echo "deploy: 1 green PR on hold, not waited for" ;;
    *) echo "deploy: $1 green PRs on hold, not waited for" ;;
  esac
}

# deploy_state GREEN LAST_EPOCH NOW INTERVAL_MIN
# One line for --status and the brief: "deploy: held, 2 green PRs waiting;
# last deploy 35 min ago" or "deploy: due; last deploy 70 min ago (interval
# 60)" or "deploy: due; none recorded".
deploy_state() {
  ds_why=$(deploy_gate "$@")
  if [ -n "$2" ]; then ds_last="last deploy $(( ($3 - $2) / 60 )) min ago"; else ds_last="none recorded"; fi
  if [ -n "$ds_why" ]; then
    case "$ds_why" in last*) echo "deploy: held, $ds_why" ;; *) echo "deploy: held, $ds_why; $ds_last" ;; esac
  else echo "deploy: due; $ds_last (interval $4)"; fi
}

# file_deps PACKAGE_JSON
# The paths of the "file:" dependencies in a package.json (dependencies,
# devDependencies, optionalDependencies), one a line, as written after
# "file:". A package installed by copy from such a path goes stale when
# the path changes on main while the lockfile does not; the queue hashes
# these trees as well as the lockfile.
file_deps() {
  printf '%s\n' "$1" | tr -d '\r' | tr ',{}' '\n\n\n' | sed -n 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*"file:\([^"]*\)".*/\1/p'
}

# generated_globs TEXT / rebuild_command TEXT
# TEXT is scripts/ci/generated-paths.txt: one shell glob per line naming
# checked-in build output, and one line "rebuild: COMMAND". Print the globs,
# or the command.
generated_globs() { printf '%s\n' "$1" | tr -d '\r' | sed 's/#.*//; /^[[:space:]]*rebuild:/d; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'; }
rebuild_command() { printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[[:space:]]*rebuild:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | head -n 1; }

# generated_only FILES TEXT
# "yes" when FILES (one path per line, at least one) all match a glob of
# TEXT'\''s generated paths; "no" otherwise, and when the list is empty.
# Two pull requests that each commit their own rebuild of a shared package
# conflict on it even when their sources do not; the queue takes either
# side and rebuilds instead of dropping one.
generated_only() {
  go_globs=$(generated_globs "$2")
  if [ -z "$go_globs" ]; then echo no; return 0; fi
  set -f
  go_any=no; go_all=yes
  for go_f in $(printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | sed '/^[[:space:]]*$/d'); do
    go_any=yes; go_hit=no
    for go_pat in $go_globs; do case "$go_f" in $go_pat) go_hit=yes; break ;; esac; done
    if [ "$go_hit" = no ]; then go_all=no; fi
  done
  set +f
  if [ "$go_any" = yes ] && [ "$go_all" = yes ]; then echo yes; else echo no; fi
}

# release_on DEPLOY_JSON: "ask" or "deploy" (the default), from "releaseOn"
# in .claude/deploy.json. "ask": the queue never starts the listed releases
# after a landing; merge-queue.sh --release starts each once, on request.
release_on() {
  ro=$(printf '%s' "$1" | tr -d '\r\n' | sed -n 's/.*"releaseOn"[ \t]*:[ \t]*"\([a-z]*\)".*/\1/p')
  case "$ro" in ask) echo ask ;; *) echo deploy ;; esac
}

# release_hold STATE ON WHY
# Why a release workflow is not started, or nothing to start it. STATE is
# its state from the API (active, disabled_manually, ...); ON is release_on;
# WHY is "landing" (after a merge) or "ask" (merge-queue.sh --release).
release_hold() {
  case "$1" in disabled*) echo "(it is turned off; a turned-off release is held on purpose)"; return 0 ;; esac
  if [ "$2" = ask ] && [ "$3" = landing ]; then echo "(releaseOn is ask; merge-queue.sh --release starts it)"; fi
}

# workspace_kind DIR
# "pnpm", "npm" or "yarn" when DIR is a workspace root (a pnpm-workspace.yaml,
# or a package.json with a "workspaces" field, the tool named by its
# lockfile), else nothing: a project of separate packages is not one.
workspace_kind() {
  if [ -f "$1/pnpm-workspace.yaml" ]; then echo pnpm
  elif [ -f "$1/package.json" ] && grep -q '"workspaces"' "$1/package.json" 2>/dev/null; then
    if [ -f "$1/yarn.lock" ] && [ ! -f "$1/package-lock.json" ]; then echo yarn; else echo npm; fi
  fi
}

# workspace_lockfile KIND: the root lockfile's name.
workspace_lockfile() {
  case "$1" in pnpm) echo pnpm-lock.yaml ;; yarn) echo yarn.lock ;; *) echo package-lock.json ;; esac
}

# workspace_globs DIR: the member globs, one a line ("packages/*").
workspace_globs() {
  if [ -f "$1/pnpm-workspace.yaml" ]; then
    tr -d '\r' < "$1/pnpm-workspace.yaml" | sed -n "s/^[[:space:]]*-[[:space:]]*['\"]\{0,1\}\([^'\"#]*[^'\"# ]\)['\"]\{0,1\}.*/\1/p" | grep -v '^!'
  else
    tr -d '\r' < "$1/package.json" 2>/dev/null | tr '\n' ' ' | sed -n 's/.*"workspaces"[[:space:]]*:[[:space:]]*\({[^}]*"packages"[[:space:]]*:[[:space:]]*\)\{0,1\}\[\([^]]*\)\].*/\2/p' | tr ',' '\n' | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
  fi
}

# workspace_members DIR: the member folders (relative, sorted) that a glob
# names and that hold a package.json. Only "folder/*" and plain folders.
workspace_members() {
  { workspace_globs "$1"; echo; } | while IFS= read -r wm_g; do
    [ -n "$wm_g" ] || continue
    wm_g=${wm_g#./}; wm_g=${wm_g%/}
    case "$wm_g" in
      */\*)
        for wm_d in "$1/${wm_g%/\*}"/*/; do
          [ -f "${wm_d}package.json" ] || continue
          wm_d=${wm_d%/}; echo "${wm_d#"$1"/}"
        done ;;
      *\**) ;;
      *) [ -f "$1/$wm_g/package.json" ] && echo "$wm_g" ;;
    esac
  done | sort -u
}

# workspace_hash DIR KIND: the root lockfile's hash plus each member's
# package.json hash, one string; changes when either does.
workspace_hash() {
  wh_f="$1/$(workspace_lockfile "$2")"
  wh_h=$( [ -f "$wh_f" ] && git hash-object "$wh_f" 2>/dev/null || echo none )
  for wh_m in $(workspace_members "$1"); do
    wh_h="$wh_h,$(git hash-object "$1/$wh_m/package.json" 2>/dev/null || echo none)"
  done
  echo "$wh_h"
}

# workspace_install_command DIR KIND: the install, run once from the root.
# pnpm comes from the path, then corepack, then npx at the major the
# lockfile's header names.
workspace_install_command() {
  case "$2" in
    pnpm)
      if command -v pnpm >/dev/null 2>&1; then echo "pnpm install --frozen-lockfile"
      elif command -v corepack >/dev/null 2>&1; then echo "corepack pnpm install --frozen-lockfile"
      else
        wi_v=$(sed -n "s/^lockfileVersion:[[:space:]]*['\"]\{0,1\}\([0-9]*\).*/\1/p" "$1/pnpm-lock.yaml" 2>/dev/null | head -n 1)
        case "$wi_v" in 9) wi_p=9 ;; 6) wi_p=8 ;; 5) wi_p=7 ;; *) wi_p=latest ;; esac
        echo "npx --yes pnpm@$wi_p install --frozen-lockfile"
      fi ;;
    yarn) echo "yarn install --immutable" ;;
    *) echo "npm ci --no-audit --no-fund" ;;
  esac
}
