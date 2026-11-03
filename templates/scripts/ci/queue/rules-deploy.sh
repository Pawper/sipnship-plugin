#!/bin/sh
# Pure helpers for pausing the drain, the release workflows and the deploy
# gate. Loaded by scripts/ci/batch-lib.sh.

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

# package_version PACKAGE_JSON: the "version" a package.json holds, or nothing.
package_version() {
  printf '%s' "$1" | tr -d '\r' | sed -n 's/^[ \t]*"version"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p' | head -n 1
}

# release_tag BEFORE AFTER PREFIX: the tag a landing pushes when it moves
# the version of the package whose release workflow runs on PREFIX tags:
# PREFIX plus AFTER's version when it differs from BEFORE's; nothing when
# it is the same or AFTER has none. BEFORE and AFTER are the package.json
# texts on the merge commit's first parent and on the merge commit. A
# release once waited half a day on a person to push the tag by hand.
release_tag() {
  rt_new=$(package_version "$2")
  [ -n "$rt_new" ] || return 0
  [ "$rt_new" = "$(package_version "$1")" ] && return 0
  printf '%s%s\n' "$3" "$rt_new"
}

# release_tag_wanted WORKFLOWS PREFIX: "yes" when a workflow's text (all
# of .github/workflows, joined) runs on a pushed tag PREFIX*, so a project
# without such a release never gets a tag it does not use.
release_tag_wanted() {
  if printf '%s\n' "$1" | grep -F -- "$2*" >/dev/null 2>&1; then echo yes; else echo no; fi
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

# deploy_waits_for NUMBER LABELS SKIP
# "yes" when a green pull request may hold the deploy: the queue can still
# merge it now. A pull request this drain tried and left open (dropped for a
# conflict or left out; SKIP is their numbers, space-separated) or one
# labelled blocked never holds a deploy: once, a pull request the same
# drain had just dropped held every deploy for most of an hour. LABELS is
# comma-separated.
deploy_waits_for() {
  case " $3 " in *" $1 "*) echo no; return 0 ;; esac
  case ",$(printf '%s' "$2" | tr 'A-Z' 'a-z')," in *blocked*) echo no; return 0 ;; esac
  echo yes
}

# deploy_hold_bound HELD_DRAINS LAST_EPOCH NOW MAX_HOLD_MIN
# Why a deploy held for green pull requests goes anyway, or nothing: after
# two drains in a row held it, or when the last deploy is older than
# MAX_HOLD_MIN (QUEUE_DEPLOY_MAX_HOLD, default 30). With steady work there is
# always one more green pull request, so a hold without a bound never ends.
deploy_hold_bound() {
  if [ "${1:-0}" -ge 2 ]; then echo "held for $1 drains in a row; the limit is 2"; return 0; fi
  if [ -n "$2" ] && [ $(( $3 - $2 )) -ge $(( ${4:-30} * 60 )) ]; then
    echo "last deploy $(( ($3 - $2) / 60 )) minutes ago, over the ${4:-30}-minute bound"
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
