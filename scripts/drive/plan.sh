#!/bin/sh
# Gather the project's state and print the proposal the project-drive skill
# would put to a person. This script never acts: it reads, decides, prints.
# The skill posts the proposal and, once approved, pursues it.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/plan.sh" [--dry-run] [--snapshot] [--fast] [--facts FILE]
# --dry-run is accepted and changes nothing: this script is always dry.
# --snapshot also prints the raw facts the proposal was made from.
# --facts FILE reuses facts already fetched by board-now.sh.
# --fast skips the one extra call for the audit issue's latest comment.
#
# The whole board comes from one GraphQL call (hooks/scripts/board-now.sh).
# Reads .claude/project-drive.json when present: runners (default 2),
# maxAgents (4), maxMinutes (90), queueLogGlob, ownerDecisions.
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/../../hooks/scripts/session-brief-lib.sh"
. "$here/drive-lib.sh"

show_snapshot=no; fast=no; facts_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) show_snapshot=yes ;;
    --fast) fast=yes ;;
    --facts) shift; facts_file=$1 ;;
  esac
  shift
done

runners=2; max_agents=4; max_minutes=90; queue_glob=""; owner_phrases=""
if [ -f .claude/project-drive.json ]; then
  cfg=$(cat .claude/project-drive.json)
  n=$(json_number "$cfg" runners); [ -n "$n" ] && runners=$n
  n=$(json_number "$cfg" maxAgents); [ -n "$n" ] && max_agents=$n
  n=$(json_number "$cfg" maxMinutes); [ -n "$n" ] && max_minutes=$n
  queue_glob=$(json_field "$cfg" queueLogGlob)
  owner_phrases=$(printf '%s' "$cfg" | awk 'BEGIN { RS = "\001" } { i = index($0, "\"ownerDecisions\""); if (!i) exit; s = substr($0, i); j = index(s, "["); k = index(s, "]"); if (!j || !k) exit; print substr(s, j + 1, k - j - 1) }' \
    | tr ',' '\n' | sed 's/^[ \t"]*//;s/[ \t"]*$//' | sed '/^$/d')
fi

if [ -n "$facts_file" ] && [ -f "$facts_file" ]; then
  facts=$(cat "$facts_file")
else
  facts=$(sh "$here/../../hooks/scripts/board-now.sh" 2>"${TMPDIR:-/tmp}/board-now.$$.err") || facts=""
fi
if [ -z "$facts" ]; then
  if [ "$(gh_refusal "$(cat "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null)")" = yes ]; then
    echo "GitHub refused the board read for its rate limit (GraphQL's secondary limit; REST may still be fine); try the round again in a few minutes, and keep one queue and one drive at a time."
    echo "stop: rate-limited"
  else
    echo "gh is not available or not signed in; the round cannot read the project."
    echo "stop: unavailable"
  fi
  rm -f "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null
  exit 0
fi
rm -f "${TMPDIR:-/tmp}/board-now.$$.err" 2>/dev/null

rules=""
[ -f scripts/ci/classes.txt ] && [ -f scripts/ci/lib.sh ] && rules=$(cat scripts/ci/classes.txt)
tab=$(printf '\t')
tmp=$(mktemp)

# Turn the facts into a snapshot, with no further network calls.
printf '%s\n' "$facts" | while IFS="$tab" read -r kind num title a b c d e; do
  case "$kind" in
    pr)
      case "$a" in SUCCESS) ci=green ;; FAILURE|ERROR) ci=red ;; *) ci=pending ;; esac
      merge=$(printf '%s' "$b" | tr 'A-Z' 'a-z')
      class=app
      if [ -n "$rules" ]; then
        cls=$(sh -c '. scripts/ci/lib.sh; classify_paths "$1" "$2"' sh "$(printf '%s' "$d" | tr ',' '\n')" "$rules")
        case " $cls " in *" app "*|*" other "*|*" tests "*|*" data "*) class=app ;; *) class=other ;; esac
      fi
      printf 'pr\t%s\t%s\t%s\t%s\t%s\n' "$num" "$title" "$ci" "$merge" "$class"
      ;;
    issue)
      state=$(state_of_labels "$a")
      case ",$a," in *",ci-red,"*) printf 'red\t%s\n' "$num" ;; esac
      case "$state" in
        ready)
          owner=no
          # Title and the start of the body, both from the one call.
          if [ -n "$owner_phrases" ] && [ -n "$(owner_decision_hit "$title $c" "$owner_phrases")" ]; then owner=yes; fi
          printf 'issue\t%s\t%s\tready\t%s\n' "$num" "$title" "$owner" ;;
        in-progress|waiting-on-owner|blocked)
          printf 'issue\t%s\t%s\t%s\tno\n' "$num" "$title" "$state" ;;
      esac
      ;;
  esac
done >> "$tmp"

# The audit issue's latest comment: one extra call, skipped with --fast.
if [ "$fast" = no ]; then
  audit_issue=$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "issue" && ("," $4 ",") ~ /,audit,/ { print $2; exit }')
  if [ -n "$audit_issue" ]; then
    last=$(gh issue view "$audit_issue" --json comments --jq '.comments[-1].body // ""' 2>/dev/null | tr '\n' ' ' | cut -c1-200)
    [ -n "$last" ] && printf 'audit\t%s\n' "$last" >> "$tmp"
  fi
fi

queue_state=none
if [ -n "$queue_glob" ]; then
  newest=""; newest_m=0
  for f in $queue_glob; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$newest_m" ]; then newest_m=$m; newest=$f; fi
  done
  if [ -n "$newest" ]; then
    if [ "$(queue_is_stale "$newest_m" "$(date +%s)" "$(tail -n 1 "$newest")")" = yes ]; then queue_state=stale; else queue_state=recent; fi
  fi
fi
printf 'queue\t%s\n' "$queue_state" >> "$tmp"

snapshot=$(cat "$tmp")
[ "$show_snapshot" = yes ] && { echo "snapshot:"; printf '%s\n' "$snapshot"; echo; }
# What the saved digest adds: goals that labels alone miss, such as an
# issue still labeled waiting on owner that the owner has answered. Only
# summaries that are current count.
extra=""
if [ -f .scratch/board/digest.tsv ] && [ -f "$here/../board/board-lib.sh" ]; then
  . "$here/../board/board-lib.sh"
  saved=$(cat .scratch/board/digest.tsv)
  extra=$(digest_goals "$facts" "$saved")
  fresh=$(digest_freshness "$facts" "$saved")
  note="digest: ${fresh%%	*} of ${fresh##*	} summaries current"
else
  note="digest: none yet; run /project-status so the proposal reads bodies and comments, not only labels"
fi

echo "proposal for $(date '+%A %Y-%m-%d'), the owner's local day (runners $runners, at most $max_agents agents, at most $max_minutes minutes; $note):"
round=$(propose_round "$snapshot" "$runners" "$max_agents")
if [ -n "$extra" ]; then
  round=$(printf '%s\n%s\n' "$extra" "$round" | awk '/^stop: (nothing to propose|everything left waits|work is in flight)/ { print "stop: proposal ready for approval"; next } { print }')
fi
number_proposal "$round"

# A pending pull request: say when to look again. One REST call for recent runs.
pend_pr=$(printf '%s\n' "$snapshot" | awk -F'\t' '$1 == "pr" && $4 == "pending" { print $2; exit }')
if [ -n "$pend_pr" ]; then
  runs=$(gh api "repos/{owner}/{repo}/actions/runs?per_page=20" --jq '.workflow_runs[] | [.status, (.run_started_at // .created_at | fromdateiso8601), (.updated_at | fromdateiso8601)] | @tsv' 2>/dev/null | tr -d '\r')
  durations=$(printf '%s\n' "$runs" | awk -F'\t' '$1 == "completed" && $3 > $2 { print $3 - $2 }')
  started=$(printf '%s\n' "$runs" | awk -F'\t' '$1 != "completed" && $1 != "" { print $2; exit }')
  secs=$(wake_after "$durations" "$started" "$(date +%s)")
  [ -n "$secs" ] && echo "wake: $secs seconds, PR $pend_pr"
fi
