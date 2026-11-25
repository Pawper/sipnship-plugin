#!/bin/sh
# Pure helpers for requests to the queue and rush changes. Loaded by
# scripts/ci/batch-lib.sh.

# --- Requests to the queue: land this next, hold, take out, release. ---
# A request is a proposal the queue honours at its ticks; it never merges
# anything red and "land this next" runs the serial path, nothing else.

# request_from_comment ID BODY: one request line "id<TAB>kind<TAB>pr<TAB>
# asked_by<TAB>reason" when BODY is exactly the fixed form, one line:
#   Queue request: land-next #48 by maya: speeds the others up
# Nothing otherwise, so a comment that only mentions landing never acts. A
# take-out ("drop") always carries its reason.
request_from_comment() {
  rc_body=$(printf '%s' "$2" | tr -d '\r')
  [ "$(printf '%s\n' "$rc_body" | wc -l | tr -d ' ')" = 1 ] || return 0
  rc_t=$(printf '\t')
  rc_l=$(printf '%s\n' "$rc_body" | sed -nE "s/^Queue request: (land-next|land-now|hold|drop|release) #([0-9]+) by ([A-Za-z0-9][A-Za-z0-9-]{0,38})(: (.+))?\$/\\1${rc_t}\\2${rc_t}\\3${rc_t}\\5/p")
  # "Deploy now" names no pull request; it is kept as 0.
  [ -n "$rc_l" ] || rc_l=$(printf '%s\n' "$rc_body" | sed -nE "s/^Queue request: deploy-now by ([A-Za-z0-9][A-Za-z0-9-]{0,38})(: (.+))?\$/deploy-now${rc_t}0${rc_t}\\1${rc_t}\\3/p")
  [ -n "$rc_l" ] || return 0
  case "$rc_l" in "drop${rc_t}"*"${rc_t}") return 0 ;; esac
  printf '%s\t%s\n' "$1" "$rc_l"
}

# request_answer_form KIND PR OUTCOME: the queue's answer on the issue road.
request_answer_form() {
  if [ "$1" = deploy-now ]; then printf 'Queue answer: deploy-now: %s\n' "$3"; else printf 'Queue answer: %s #%s: %s\n' "$1" "$2" "$3"; fi
}

# deploy_run_outcome STATUS CONCLUSION: what a deploy-now request answers
# once its Deploy run is read: nothing while it runs, deployed or
# deploy-failed when it ends.
deploy_run_outcome() {
  [ "$1" = completed ] || return 0
  if [ "$2" = success ]; then echo deployed; else echo deploy-failed; fi
}

# classes_overlap A B: "yes" when the two space-separated class lists share one.
classes_overlap() {
  for co_a in $1; do for co_b in $2; do
    if [ "$co_a" = "$co_b" ]; then echo yes; return 0; fi
  done; done
  return 0
}

# hold_line_stripped BODY: BODY with every "Queue: hold" line taken out, the same
# line held_reason reads, so a release that takes the label off takes this mark
# off too (#2514). Every other line is kept as it is.
hold_line_stripped() {
  printf '%s\n' "$1" | grep -viE '^[[:space:]]*queue:[[:space:]]*hold' || true
}

# release_outcome LABELS BODY: what a release request answers once it has done
# what it can, read from what the change still carries: "released" only when no
# hold remains; "hold-label-kept" while a hold label is still on it; else
# "hold-line-kept" while its text still carries the line (#2514).
release_outcome() {
  if printf '%s\n' "$1" | tr -d '\r' | grep -qixE 'queue:hold|hold'; then echo hold-label-kept; return 0; fi
  if printf '%s\n' "$2" | tr -d '\r' | grep -qiE '^[[:space:]]*queue:[[:space:]]*hold'; then echo hold-line-kept; return 0; fi
  echo released
}

# land_next_step ROLLUP CONFLICTS BATCH_RUNNING OVERLAP: what "land this
# next" does at a tick. red and conflicts end the request; wait leaves it
# open; after-batch lands it first once the batch lands; serial-now runs the
# serial path at once (between rounds, or beside a running batch whose
# classes it does not share, the rule the queue already merges under).
# A fifth word, the required check's state on the head, keeps a request
# waiting while that check still runs: only a finished failure is red.
land_next_step() {
  if [ "$2" = yes ]; then echo conflicts; return 0; fi
  case "$1" in red) if [ "${5:-}" = pending ]; then echo wait; else echo red; fi; return 0 ;; green) ;; *) echo wait; return 0 ;; esac
  if [ "$3" = yes ] && [ "$4" = yes ]; then echo after-batch; else echo serial-now; fi
}

# requests_waiting_on LINES MEMBERS DONE: while a batch is being built no
# request can land, so each land request not yet answered hears why, one
# "id<TAB>kind<TAB>pr<TAB>outcome" a line: a member of the batch lands with it,
# any other lands the moment the batch's round lets go of the queue.
requests_waiting_on() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v m=" $(printf '%s' "$2" | tr '\n' ' ') " -v done=" $(printf '%s' "$3" | tr '\n' ' ') " '
    ($2 == "land-next" || $2 == "land-now") && $3 != "" && index(done, " " $1 " ") == 0 {
      printf "%s\t%s\t%s\t%s\n", $1, $2, $3, (index(m, " " $3 " ") ? "next-after-batch" : "after-drain")
    }'
}

# rush_only OPEN RUSH: the rows of OPEN (pull request first) a rush list keeps.
# With a rush standing the others are not read, so nothing running counts
# against it and the drain's hold for others' CI never applies to it.
rush_only() {
  printf '%s\n' "$1" | awk -F'\t' -v k=" $2 " 'NF && index(k, " " $1 " ")'
}

# rush_landable OPEN RUSH: the rush pull requests (a line each, in RUSH's
# order) whose row in OPEN reads green. A rush change that cannot land yet
# (its checks run, or failed) does not pause the others.
rush_landable() {
  for rl in $2; do
    printf '%s\n' "$1" | awk -F'\t' -v n="$rl" '$1 == n && $4 == "green" { print $1 }'
  done
}

# rush_pick PICK RUSH_FIRST: the lines of PICK equal to RUSH_FIRST; prints
# nothing, and never fails, when the rush change is not among them (a
# failing grep here once ended every drain with exit 1 and no reason).
rush_pick() {
  printf '%s\n' "$1" | grep -x "$2" || true
}

# --- Rush changes: "land this next" reserves the machines ---
# A rush pull request's checks run alone: the queue cancels every other
# pull request's running and queued checks (never a batch's run, a rush
# test head's or a run on main), notes each as paused, and re-runs them
# once, oldest first, when the rush list is empty. The rush list is a
# chain: each one after the first is tested on main plus those ahead of it.
RUSH_MARKER='<!-- merge-queue:rush -->'
RUSH_PAUSED_SAY='Paused for a rush change'

# rush_order LINES DONE: the land-now (rush) pull requests, one a line, in the
# order asked. LINES is requests_open's "id<TAB>kind<TAB>pr<TAB>by<TAB>
# reason", oldest first; DONE the request ids already answered.
rush_order() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v done=" $(printf '%s' "$2" | tr '\n' ' ') " '
    $2 == "land-now" && $3 != "" && index(done, " " $1 " ") == 0 && !seen[$3]++ { print $3 }'
}

# rush_cancel_pick RUNS BASE KEEP: the runs to cancel for a rush, one
# "run<TAB>pr<TAB>head" a line. RUNS is one run a line, "id<TAB>status<TAB>
# event<TAB>branch<TAB>pr<TAB>head". Only a pull request's run that is not
# completed, never one on BASE, never one without a pull request (a
# deploy, a schedule), never one of KEEP (the rush ones, the batches and
# the rush test heads).
rush_cancel_pick() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v keep=" $(printf '%s' "$3" | tr '\n' ' ') " '
    NF >= 5 && $2 != "completed" && $3 == "pull_request" && $4 != base && $5 != "" && index(keep, " " $5 " ") == 0 && !seen[$1]++ { printf "%s\t%s\t%s\n", $1, $5, $6 }'
}

# rush_chain RUSH: one line per rush pull request, "pr<TAB>those ahead",
# the ones ahead space-separated; the first has none.
rush_chain() {
  printf '%s\n' $1 | awk 'NF { printf "%s\t%s\n", $1, ahead; ahead = (ahead == "" ? $1 : ahead " " $1) }'
}

# rush_head_name PR AHEAD: the test head's branch, main plus AHEAD plus PR.
rush_head_name() { printf 'rush-%s-on-%s\n' "$1" "$(printf '%s' "$2" | tr ' ' '-')"; }

# rush_step OWN CONFLICTS AHEAD_LEFT HEAD_ROLLUP TREE_SAME: what a rush pull
# request does at a tick. conflicts and red end it; "chain" while one ahead
# of it has not landed (its test head runs meanwhile); "proven" when all
# ahead have landed, its test head is green and main plus it is the tree
# that head tested: it merges on that result with no further run;
# otherwise land_next_step's own rule on its own checks.
rush_step() {
  if [ "$2" = yes ]; then echo conflicts; return 0; fi
  if [ "$1" = red ]; then echo red; return 0; fi
  if [ -n "$(printf '%s' "$3" | tr -d ' ')" ]; then echo chain; return 0; fi
  if [ "$4" = green ] && [ "$5" = yes ]; then echo proven; return 0; fi
  land_next_step "$1" "" no no
}

# rush_reruns PAUSED: the paused pull requests, oldest pause first, each
# once. PAUSED is "pr<TAB>run<TAB>epoch<TAB>head" a line.
rush_reruns() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' 'NF >= 3 { print $3 "\t" NR "\t" $1 }' | sort -n -k1,1 -k2,2 | awk -F'\t' '!seen[$3]++ { print $3 }'
}

# runner_rows RUNNERS JOBS CANCELLED RUSH_WAITING: one row a machine,
# "name<TAB>state<TAB>say". RUNNERS is "name<TAB>status" a line; JOBS is
# "runner<TAB>run<TAB>step" for every job GitHub lists as not completed;
# CANCELLED the runs the queue cancelled; RUSH_WAITING the rush pull
# request whose jobs are queued, or nothing. A machine is free only when
# GitHub lists no job on it: a cancelled run's step runs to its end on a
# Windows runner, and the report job runs after a cancel.
runner_rows() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v jobs="$2" -v cancelled=" $(printf '%s' "$3" | tr '\n' ' ') " -v rush="$4" '
    BEGIN { n = split(jobs, jl, "\n"); for (i = 1; i <= n; i++) { split(jl[i], f, "\t"); if (f[1] == "") continue; if (index(cancelled, " " f[2] " ")) fin[f[1]] = 1; else live[f[1]] = 1 } }
    NF >= 1 && $1 != "" {
      if ($2 != "online") printf "%s\toffline\t\n", $1
      else if (live[$1]) printf "%s\tbusy\t\n", $1
      else if (fin[$1]) printf "%s\tfinishing\tfinishing a cancelled run\n", $1
      else if (rush != "") printf "%s\treserved\tReserved for #%s\n", $1, rush
      else printf "%s\tfree\t\n", $1
    }'
}

# runners_free ROWS: how many machines runner_rows found with no job.
runners_free() { printf '%s\n' "$1" | awk -F'\t' '$2 == "free" || $2 == "reserved" { c++ } END { print c + 0 }'; }

# --- Runners kept for the batch and main (scripts/ci/RUNNERS.md) ---
# Every runner carries the pr label but the kept ones, so pull requests
# never take the machine a batch or main is waiting for. The queue keeps
# the labels itself; a person never sets them.
KEEP_LABEL=pr
# The kept machines also carry this label, so a batch's jobs can ask for them by name
# (the runs-on expression in ci.yml) instead of taking any machine, ordinary ones included (#2856).
KEPT_LABEL=kept

# keep_count ONLINE GREEN [LANDING]: how many machines to keep for landing.
# None with fewer than two online; one while nothing waits green and no
# batch is in its checks; while either is so, half the online machines and
# at least two (the drain holds one, and a batch's dozen jobs need the
# rest); never the last machine, so changes' own checks always have one.
# Every number is read from GitHub at the drain, never kept in a file.
keep_count() {
  awk -v on="${1:-0}" -v g="${2:-0}" -v l="${3:-0}" 'BEGIN { if (on + 0 < 2) { print 0; exit }
    k = 1; if (g + 0 > 0 || l + 0 > 0) { k = int(on / 2); if (k < 2) k = 2 }
    if (k > on - 1) k = on - 1; print k }'
}

# landing_now PULLS: how many batches (or rush test heads) are in their
# checks: open, non-draft pull requests from a batch-* or rush-* branch.
# PULLS is "number<TAB>draft<TAB>sha<TAB>head branch" a line.
landing_now() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 != "" && $2 != "true" && ($4 ~ /^batch-/ || $4 ~ /^rush-/) { c++ } END { print c + 0 }'
}

# keep_why ONLINE GREEN LANDING: the drain's log line, how many machines
# are kept for landing and why.
keep_why() {
  kw_k=$(keep_count "$1" "$2" "$3")
  awk -v on="${1:-0}" -v g="${2:-0}" -v l="${3:-0}" -v k="$kw_k" 'BEGIN {
    if (k + 0 == 0) { print "none kept for landing: fewer than two machines online."; exit }
    w = ""; if (g + 0 > 0) w = g " " (g + 0 == 1 ? "change waits" : "changes wait") " green"
    if (l + 0 > 0) w = (w == "" ? "" : w " and ") "a batch is in its checks"
    if (w == "") w = "nothing waits green"
    print k " of " on " machines kept for landing: " w "." }'
}

# green_waiting PULLS SUCCESSES: how many open, non-draft changes have a
# green run of CI on their current head. PULLS is "number<TAB>draft<TAB>sha"
# a line, and a fourth field, the head branch, when known: a batch or rush
# test head is not a change waiting (landing_now counts it). SUCCESSES is
# one head sha a line, from the workflow's green runs.
green_waiting() {
  printf '%s\n' "$2" | tr -d '\r' | awk -F'\t' -v pulls="$1" '
    BEGIN { n = split(pulls, rows, "\n"); for (i = 1; i <= n; i++) { split(rows[i], f, "\t"); if (f[1] != "" && f[2] != "true" && f[4] !~ /^(batch|rush)-/) want[f[3]] = f[1] } }
    $1 != "" && ($1 in want) && !seen[want[$1]]++ { c++ }
    END { print c + 0 }'
}

# kept_say KEPT: the Queue's line about the machines kept for landing.
kept_say() {
  case "$1" in 0|"") return 0 ;; 1) echo "1 machine kept for landing" ;; *) echo "$1 machines kept for landing" ;; esac
}

# runner_label_plan RUNNERS [KEEP]: the label changes that leave exactly
# KEEP (default one) online runners without the label, one
# "add|remove<TAB>id<TAB>name" a line, nothing when the labels are already
# right. RUNNERS is one runner a line, "id<TAB>name<TAB>status<TAB>labels"
# (comma-joined). The kept ones are the online runners already without the
# label, the oldest by id first, then the oldest online ones, so a role
# moves only when its runner goes offline. With fewer than two online,
# none is kept: all carry it.
runner_label_plan() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v lab="$KEEP_LABEL" -v want="${2:-1}" '
    NF >= 3 && $1 != "" { n++; id[n] = $1 + 0; nm[n] = $2; on[n] = ($3 == "online"); has[n] = (index("," $4 ",", "," lab ",") > 0) ? 1 : 0; if (on[n]) online++ }
    END { if (online < 2) want = 0; if (want > online - 1) want = online - 1
      for (i = 1; i <= n; i++) if (on[i]) { r = 1
        for (j = 1; j <= n; j++) if (on[j] && j != i && (has[j] < has[i] || (has[j] == has[i] && id[j] < id[i]))) r++
        rank[i] = r }
      for (i = 1; i <= n; i++) {
        if (on[i] && rank[i] <= want) { if (has[i]) printf "remove\t%s\t%s\n", id[i], nm[i] }
        else if (!has[i]) printf "add\t%s\t%s\n", id[i], nm[i] } }'
}

# kept_label_plan RUNNERS: the label changes that leave the kept label on exactly
# the runners that lack the pr label, one "add|remove<TAB>id<TAB>name" a line,
# nothing when it is already right. RUNNERS is the same lines runner_label_plan
# reads, as they stand once its changes are made. An offline runner is judged
# like the others, so a role that moves with its runner never needs a second
# pass. With every runner carrying pr (fewer than two online, or the queue
# cannot manage runners) no runner carries kept, and a batch's jobs then ask
# for any machine, as ci.yml says while CI_KEEP_RUNNER is not on.
kept_label_plan() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v pr="$KEEP_LABEL" -v kept="$KEPT_LABEL" '
    NF >= 3 && $1 != "" { l = "," $4 ","; has_pr = index(l, "," pr ",") > 0; has_kept = index(l, "," kept ",") > 0
      if (!has_pr && !has_kept) printf "add\t%s\t%s\n", $1, $2
      else if (has_pr && has_kept) printf "remove\t%s\t%s\n", $1, $2 }'
}

# plan_applied RUNNERS PLAN: RUNNERS as they stand once runner_label_plan's PLAN
# has been made, so the kept label is planned from the labels the drain just set.
plan_applied() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v plan="$2" -v pr="$KEEP_LABEL" '
    BEGIN { n = split(plan, pl, "\n"); for (i = 1; i <= n; i++) { split(pl[i], f, "\t"); if (f[2] != "") act[f[2]] = f[1] } }
    NF >= 3 && $1 != "" { l = $4
      if (($1 in act) && act[$1] == "add") l = (l == "" ? pr : l "," pr)
      else if (($1 in act) && act[$1] == "remove") { t = "," l ","; sub("," pr ",", ",", t); gsub(/^,|,$/, "", t); l = t }
      printf "%s\t%s\t%s\t%s\n", $1, $2, $3, l }'
}

# keep_runner_var MANAGED NOW: what to set the CI_KEEP_RUNNER variable to,
# or nothing when it is already so. "on" once the queue has the labels
# right; "off" when its token cannot manage runners, so pull requests take
# any runner rather than wait on a label nobody keeps.
keep_runner_var() {
  if [ "$1" = yes ]; then kv=on; else kv=off; fi
  [ "$2" = "$kv" ] || echo "$kv"
}

# say_with_need SAY NOTE: publish_say's three lines with NOTE added to the
# third, what needs a person; SAY as it was when NOTE is empty.
say_with_need() {
  printf '%s\n' "$1" | awk -v n="$2" 'NR == 3 && n != "" { $0 = ($0 == "Nothing needs you." ? n : $0 " " n) } { print }'
}

# say_with_kept SAY KEPT_LINE: publish_say's three lines with KEPT_LINE
# (kept_say's own words, "N machines kept for landing") added to the
# first, what the queue is doing now; SAY as it was when KEPT_LINE is
# empty (fewer than two runners online, so none is kept).
say_with_kept() {
  printf '%s\n' "$1" | awk -v k="$2" 'NR == 1 && k != "" { $0 = $0 " " k "." } { print }'
}

# runner_label_problem RUNNERS: the nightly audit's line when no online
# runner is kept, or none carries the label; nothing when it is right or
# when fewer than two are online (the audit says that already).
runner_label_problem() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v lab="$KEEP_LABEL" '
    NF >= 3 && $3 == "online" { online++; if (index("," $4 ",", "," lab ",")) carry++; else bare++ }
    END { if (online < 2) exit
      if (!bare) print "No runner is kept for the batch and main: every online runner carries the " lab " label. The merge queue sets the labels at its next drain; if it cannot, its token cannot manage runners."
      else if (!carry) print "No online runner carries the " lab " label, so pull requests wait for a machine. The merge queue sets the labels at its next drain; if it cannot, its token cannot manage runners."
      else { most = int(online / 2); if (most < 2) most = 2; if (most > online - 1) most = online - 1
        if (bare > most) print "More than half the online runners lack the " lab " label; at most " most " of " online " are kept for the batch and main. The merge queue sets the labels at its next drain." } }'
}
