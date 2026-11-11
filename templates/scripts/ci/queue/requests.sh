#!/bin/sh
# Requests to the queue: land this next, land now, hold, take out, release.
# Sourced by scripts/ci/merge-queue.sh; functions only.

# --- Requests to the queue: land this next, hold this, take it out ---
# A person, their agent or the dashboard's helper asks; the queue honours
# the request at the ticks it already wakes on (each drain round's start,
# each two-minute hold, each two minutes of a batch's run), so a request
# takes effect within two minutes. Read through the service road when this
# machine is connected, else as comments in a fixed form on the Merge queue
# issue. A request never merges red: "land this next" runs --serial and
# nothing else. Bounded, never fatal: a request that cannot be read is said
# once and the queue goes on without it.
req_road=""; req_id=""; req_token=""; req_issue=""
[ ! -f "$here/queue/rule-issues.sh" ] || . "$here/queue/rule-issues.sh"
requests_road_set() {
  # Asked at each tick: an identity token lives only minutes (service-auth.sh).
  [ -n "${QUEUE_SERVICE_AUTH_LOADED:-}" ] || { . "$here/service-auth.sh"; QUEUE_SERVICE_AUTH_LOADED=1; }
  req_road=issue
  if service_sign_in; then req_token=$sv_token; req_id=$sv_id; req_road=service; fi
  return 0
}

# requests_open: the open requests, one "id kind pr asked_by reason" a line.
requests_open() {
  case "$req_road" in
    service)
      if ! printf 'Authorization: Bearer %s\n' "$req_token" | curl -s -f --max-time 5 -H @- "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$req_id/queue/requests/open" 2>/dev/null | tr -d '\r'; then
        [ -f "$flaky_dir/requests.unreachable" ] || { say "Requests to the queue could not be read from SipNShip; going on without them." >&2; : > "$flaky_dir/requests.unreachable"; }
      fi ;;
    issue)
      [ -n "$req_issue" ] || req_issue=$(gh api "repos/{owner}/{repo}/issues?labels=queue&state=all&per_page=20" --jq '[.[] | select(.title == "Merge queue")] | .[0].number // empty' 2>/dev/null | tr -d '\r')
      [ -n "$req_issue" ] || return 0
      # Only a one-line comment in the exact form, whose author is the one it names.
      gh api "repos/{owner}/{repo}/issues/$req_issue/comments?per_page=100&since=$(iso_utc $(( $(date +%s) - 2 * 86400 )))" \
        --jq '.[] | select((.body | test("[\r\n]")) | not) | "\(.id)\t\(.user.login)\t\(.body)"' 2>/dev/null | tr -d '\r' \
        | while IFS="$tab" read -r ro_id ro_login ro_body; do
          ro_l=$(request_from_comment "$ro_id" "$ro_body")
          [ -n "$ro_l" ] || continue
          [ "$(printf '%s' "$ro_l" | cut -f4)" = "$ro_login" ] || continue
          printf '%s\n' "$ro_l"
        done ;;
  esac
  return 0
}

# requests_answer ID KIND PR OUTCOME: record what the queue did, on the
# road the request came by. "next-after-batch" and "after-drain" are steps,
# not the end.
requests_answer() {
  if [ "$4" = next-after-batch ] || [ "$4" = after-drain ] || [ "$4" = deploying ]; then
    grep -qx "$1" "$flaky_dir/requests.after" 2>/dev/null && return 0
    printf '%s\n' "$1" >> "$flaky_dir/requests.after"
  else
    printf '%s\n' "$1" >> "$flaky_dir/requests.done"
  fi
  say "request: $2 #$3: $4"
  requests_road_set
  case "$req_road" in
    service) printf 'Authorization: Bearer %s\n' "$req_token" | curl -s -o /dev/null --max-time 5 -X POST -H @- -H 'content-type: application/json' --data "{\"outcome\":\"$4\"}" "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$req_id/queue/requests/$1/outcome" 2>/dev/null || true ;;
    issue) [ -z "$req_issue" ] || gh_write api -X POST "repos/{owner}/{repo}/issues/$req_issue/comments" -f body="$(request_answer_form "$2" "$3" "$4")" >/dev/null 2>&1 || true ;;
  esac
  return 0
}


# requests_deploy_now ID BY: "Deploy now", inside the current drain. The
# person's word stands in for the interval and the green-others wait, as
# the Deploy workflow's own manual dispatch does; the gate's "nothing that
# ships changed" rule still holds. Started once; later ticks read its run.
requests_deploy_now() {
  dn_mark="$flaky_dir/requests.deploy-$1"
  # Started by another drain, on another machine: its marker is a ref on
  # GitHub, so this one reads the run's result instead of starting a second.
  if ! grep -qx "$1" "$flaky_dir/requests.after" 2>/dev/null; then
    dn_ref=$(gh api "repos/{owner}/{repo}/git/matching-refs/queue/deploy-$1-" --jq '.[0].ref // empty' 2>/dev/null | tr -d '\r')
    if [ -n "$dn_ref" ]; then printf '%s\n' "${dn_ref##*-}" > "$dn_mark"; printf '%s\n' "$1" >> "$flaky_dir/requests.after"; fi
  fi
  if grep -qx "$1" "$flaky_dir/requests.after" 2>/dev/null; then
    dn_since=$(cat "$dn_mark" 2>/dev/null)
    dn_run=$(gh api "repos/{owner}/{repo}/actions/workflows/deploy.yml/runs?event=workflow_dispatch&per_page=1&created=>=$(iso_utc "${dn_since:-0}")" --jq '.workflow_runs[0] | "\(.status)\t\(.conclusion // "")"' 2>/dev/null | tr -d '\r')
    dn_out=$(deploy_run_outcome "${dn_run%%	*}" "${dn_run#*	}")
    [ -z "$dn_out" ] || requests_answer "$1" deploy-now 0 "$dn_out"
    return 0
  fi
  git fetch -q origin "$base" 2>/dev/null || true
  dn_end=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
  dn_from=$(git ls-remote origin refs/deploy/production 2>/dev/null | cut -f1)
  if [ -n "$dn_from" ] && { [ "$dn_from" = "$dn_end" ] || [ "$(ships_since "$dn_from" "$dn_end")" = skip ]; }; then
    requests_answer "$1" deploy-now 0 nothing-to-deploy
    return 0
  fi
  if [ ! -f .github/workflows/deploy.yml ]; then
    say "request: deploy-now: this project has no Deploy workflow; main deploys on its own."
    requests_answer "$1" deploy-now 0 nothing-to-deploy
    return 0
  fi
  date +%s > "$dn_mark"
  gh_write api -X POST "repos/{owner}/{repo}/git/refs" -f ref="refs/queue/deploy-$1-$(cat "$dn_mark")" -f sha="$dn_end" >/dev/null 2>&1 || true
  if gh_write api -X POST "repos/{owner}/{repo}/actions/workflows/deploy.yml/dispatches" -f ref="$base" >/dev/null 2>&1; then
    say "Started the Deploy workflow now, as $2 asked."
    requests_answer "$1" deploy-now 0 deploying
  else
    say "$(deploy_refused_message "$base")"
    requests_answer "$1" deploy-now 0 deploy-failed
  fi
  return 0
}

# requests_waiting MEMBERS: a batch is being built, which reads no requests
# for as long as its members take. So a land request hears what it waits on
# rather than look stuck; the drain's next tick lands it.
requests_waiting() {
  [ -z "${QUEUE_IN_REQUEST:-}" ] || return 0
  requests_road_set
  requests_waiting_on "$(requests_open)" "$1" "$(cat "$flaky_dir/requests.done" 2>/dev/null)" | while IFS="$tab" read -r rw_id rw_kind rw_pr rw_out; do
    requests_answer "$rw_id" "$rw_kind" "$rw_pr" "$rw_out"
  done
  return 0
}

# requests_closed KIND SHA: how a request on a closed pull request ends. A
# batch's member shows closed, not merged, once it is on main: that landed.
requests_closed() {
  case "$1" in land-next|land-now) ;; *) echo not-open; return 0 ;; esac
  git fetch -q origin "$base" 2>/dev/null || true
  if [ -n "$2" ] && git merge-base --is-ancestor "$2" "origin/$base" 2>/dev/null; then echo landed; else echo not-open; fi
}

requests_classes() { classify_paths "$(gh api "repos/{owner}/{repo}/pulls/$1/files?per_page=100" --jq '.[].filename' 2>/dev/null)" "$rules"; }

# rt_at STEP: the step the tick is at, kept in a file so a failure names it
# even when it happens inside the loop's own shell.
rt_at() { printf '%s' "$1" > "$flaky_dir/requests.step" 2>/dev/null || true; }

# requests_tick WHERE: honour the open requests, and never stop the drain.
# The body runs in its own shell under set -e; a failure in it is said with
# the step it was at and the drain goes on to the open pull requests. A
# failed tick with requests open is remembered (requests.open) for the
# drain's one retry.
requests_tick() {
  [ -z "${QUEUE_IN_REQUEST:-}" ] || return 0
  rt_e=no; case $- in *e*) rt_e=yes; set +e ;; esac
  rt_at "starting"
  (
    set -e
    trap 'rt_rc=$?; if [ "$rt_rc" -ne 0 ]; then say "Requests could not be read through: $(cat "$flaky_dir/requests.step" 2>/dev/null) (exit $rt_rc); the drain goes on to the open pull requests."; : > "$flaky_dir/requests.failed" 2>/dev/null || true; fi' EXIT
    requests_tick_body "$1"
  )
  [ "$rt_e" != yes ] || set -e
  return 0
}

# requests_tick_body WHERE: WHERE is "drain" between rounds, or "batch"
# while a batch's full run is in flight.
requests_tick_body() {
  rt_at "signing in to the road (requests_road_set)"
  requests_road_set
  [ "$req_road" != none ] || return 0
  # Project-rule requests are filed as issues between rounds (spec 016).
  rt_at "filing rule requests (rule_issues_file)"
  [ "$1" != drain ] || rule_issues_file
  rt_at "reading the open requests (requests_open)"
  rt_lines=$(requests_open)
  # A rush reserves the machines first, at the very tick it is read.
  rt_at "reading the rush order (rush_order)"
  rt_rush=$(rush_order "$rt_lines" "$(cat "$flaky_dir/requests.done" 2>/dev/null)")
  rt_at "reserving the machines for a rush (rush_tick)"
  rush_tick "$rt_rush"
  [ -n "$rt_lines" ] || return 0
  # Open requests are known: a drain that fails from here on is retried once.
  : > "$flaky_dir/requests.open" 2>/dev/null || true
  # No batch record yet is no batch: tr on a missing file would end the drain.
  rt_at "reading the batch's members (batch.members)"
  rt_members=$({ cat "$flaky_dir/batch.members" 2>/dev/null || true; } | tr '\n' ' ')
  printf '%s\n' "$rt_lines" | while IFS="$tab" read -r rq_id rq_kind rq_pr rq_by rq_why; do
    [ -n "$rq_id" ] || continue
    grep -qx "$rq_id" "$flaky_dir/requests.done" 2>/dev/null && continue
    rt_at "honouring request $rq_id, $rq_kind #$rq_pr (requests_tick_body)"
    if [ "$rq_kind" = deploy-now ]; then requests_deploy_now "$rq_id" "$rq_by"; continue; fi
    rq_state=$(gh api "repos/{owner}/{repo}/pulls/$rq_pr" --jq '"\(.state)\t\(.head.sha)\t\(.mergeable_state // "")"' 2>/dev/null | tr -d '\r')
    [ -n "$rq_state" ] || continue
    rq_rest=${rq_state#*	}; rq_sha=${rq_rest%%	*}
    if [ "${rq_state%%	*}" != open ]; then requests_answer "$rq_id" "$rq_kind" "$rq_pr" "$(requests_closed "$rq_kind" "$rq_sha")"; continue; fi
    case "$rq_kind" in
      hold)
        gh_write api -X POST "repos/{owner}/{repo}/issues/$rq_pr/labels" -f "labels[]=queue:hold" >/dev/null 2>&1 && requests_answer "$rq_id" hold "$rq_pr" held ;;
      release)
        gh_write api -X DELETE "repos/{owner}/{repo}/issues/$rq_pr/labels/queue:hold" >/dev/null 2>&1 || true
        requests_answer "$rq_id" release "$rq_pr" released ;;
      drop)
        if [ -f "$here/../worktrees.sh" ] && sh "$here/../worktrees.sh" close "$rq_pr" "Taken out of the queue at the request of $rq_by: $rq_why" >/dev/null 2>&1; then
          requests_answer "$rq_id" drop "$rq_pr" dropped
        fi ;;
      land-next|land-now)
        rq_conf=""; [ "$(mergeable_word "${rq_rest#*	}")" = CONFLICTING ] && rq_conf=yes
        rq_batch=no; rq_over=no
        case " $rt_members " in *" $rq_pr "*) continue ;; esac
        # Never past a hold: a change held for the builder to read is landed only by the builder letting it land
        # (the hold goes), never by a land request, whoever asked. A second guard beside the service's own refusal.
        rq_hold=$(gh api "repos/{owner}/{repo}/pulls/$rq_pr" --jq '([.labels[].name] | join("\n")) + "\u0001" + ((.body // "") | gsub("\r"; ""))' 2>/dev/null || true)
        if [ -n "$(held_reason "${rq_hold%%$(printf '\001')*}" "${rq_hold#*$(printf '\001')}")" ]; then
          say "request: not landing #$rq_pr, it is held for the builder to read; $rq_by's ${rq_kind#land-} request is answered held"
          requests_answer "$rq_id" "$rq_kind" "$rq_pr" held
          continue
        fi
        # A rush has the machines alone: a Land now, already green, goes straight after it.
        if [ "$rq_kind" = land-now ] && [ -n "$(printf '%s' "$rt_rush" | tr -d ' \n')" ]; then requests_answer "$rq_id" land-now "$rq_pr" after-drain; continue; fi
        # The chain: behind another rush one it waits on its test head; once
        # those ahead have landed, a green test head of the same tree is
        # its result, and it merges with no further run.
        rq_ahead=$(rush_chain "$rt_rush" | awk -F'\t' -v p="$rq_pr" '$1 == p { print $2 }')
        rq_proof=""; [ -n "$rq_ahead" ] || rq_proof=$(rush_proof "$rq_pr" "$rq_sha")
        case "$(rush_step "$(pr_rollup "$rq_sha")" "$rq_conf" "$rq_ahead" "${rq_proof%%	*}" "$(printf '%s' "$rq_proof" | cut -f2)")" in
          chain) continue ;;
          proven)
            say "request: landing #$rq_pr next on its test head's green run, as $rq_by asked${rq_why:+ ($rq_why)}"
            QUEUE_CHAIN_PROVEN=yes QUEUE_IN_DRAIN=1 QUEUE_IN_REQUEST=1 sh "$0" --serial --base "$base" --because "landing next at the request of $rq_by" "$rq_pr" 2>&1 | tee -a "$log_file" || true
            rm -f "$flaky_dir/pr-$rq_pr.tsv" 2>/dev/null
            if [ "$(gh api "repos/{owner}/{repo}/pulls/$rq_pr" --jq .merged 2>/dev/null)" = true ]; then requests_answer "$rq_id" "$rq_kind" "$rq_pr" landed; fi
            continue ;;
        esac
        if [ "$1" = batch ] && [ -n "$(printf '%s' "$rt_members" | tr -d ' ')" ]; then
          rq_batch=yes
          rq_over=$(classes_overlap "$(requests_classes "$rq_pr")" "$(for rq_m in $rt_members; do requests_classes "$rq_m"; echo; done)")
        fi
        case "$(land_next_step "$(pr_rollup "$rq_sha")" "$rq_conf" "$rq_batch" "$rq_over")" in
          red) requests_answer "$rq_id" "$rq_kind" "$rq_pr" red ;;
          conflicts) requests_answer "$rq_id" "$rq_kind" "$rq_pr" conflicts ;;
          after-batch) requests_answer "$rq_id" "$rq_kind" "$rq_pr" next-after-batch ;;
          serial-now)
            say "request: landing #$rq_pr ${rq_kind#land-}, as $rq_by asked${rq_why:+ ($rq_why)}"
            QUEUE_IN_DRAIN=1 QUEUE_IN_REQUEST=1 sh "$0" --serial --base "$base" --because "landing ${rq_kind#land-} at the request of $rq_by" "$rq_pr" 2>&1 | tee -a "$log_file" || true
            rm -f "$flaky_dir/pr-$rq_pr.tsv" 2>/dev/null
            if [ "$(gh api "repos/{owner}/{repo}/pulls/$rq_pr" --jq .merged 2>/dev/null)" = true ]; then requests_answer "$rq_id" "$rq_kind" "$rq_pr" landed; fi ;;
          *) : ;;
        esac ;;
    esac
  done
  return 0
}

