#!/bin/sh
# The round is the batch. Sourced by scripts/ci/merge-queue.sh; functions only.
#
# The drive starts a round by posting a marker on the drive issue:
#   <!-- sipnship-proposal {"status":"started","units":[{"issues":[784],"areas":[..],"pr":979}, ...],"held":[...]} -->
# A unit carries "pr" once its pull request is open, so the round's members
# are named by pull request. While that round runs the drain batches exactly
# its members: it waits (up to the hold's bound) for a member still running
# its checks or still being built, and a member that goes ahead after the
# bound lands with one line saying why. A member that is held, red, in
# conflict or gone is set aside: it is not waited on.

# round_marker COMMENTS: the newest "started" marker line of the comments
# (one comment body per line, or whole bodies), or nothing.
round_marker() {
  printf '%s\n' "$1" | tr -d '\r' | grep -F 'sipnship-proposal {"status":"started"' | tail -n 1
}

# round_parse MARKER: "PRS<TAB>UNBUILT" for the marker's units (not its held
# work): the pull request numbers, space separated, and how many units have
# no pull request yet. Nothing when the line has no units.
round_parse() {
  rp_body=$(printf '%s\n' "$1" | sed 's/.*sipnship-proposal //; s/,"held":.*//')
  rp_units=$(printf '%s\n' "$rp_body" | grep -oE '\{"issues":\[[0-9, ]*\][^}]*\}')
  [ -n "$rp_units" ] || return 0
  printf '%s\n' "$rp_units" | awk '
    { if (match($0, /"pr":[0-9]+/)) prs = prs (prs == "" ? "" : " ") substr($0, RSTART + 5, RLENGTH - 5); else un++ }
    END { printf "%s\t%d\n", prs, un + 0 }'
}

# round_pool OPEN PRS: OPEN's lines (number<TAB>draft<TAB>mergeable<TAB>rollup
# <TAB>base) of the round's members when at least one member is green or
# still running; OPEN unchanged otherwise (no round, or nothing of it left to
# wait for or merge).
round_pool() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v m=" $2 " '
    NF >= 5 { all[++n] = $0; if (index(m, " " $1 " ") > 0) { mem[n] = 1; if ($2 == "false" && toupper($3) != "CONFLICTING" && ($4 == "green" || $4 == "pending" || $4 == "cancelled")) live = 1 } }
    END { for (i = 1; i <= n; i++) if (!live || mem[i]) print all[i] }'
}

# round_outstanding POOL PRS UNBUILT: how many members the round still waits
# for: the ones running their checks, plus the units without a pull request.
# Zero when the pool is not narrowed to the round (no member left to land).
round_outstanding() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v m=" $2 " -v un="${3:-0}" '
    NF >= 5 && index(m, " " $1 " ") > 0 { seen = 1; if ($2 == "false" && ($4 == "pending" || $4 == "cancelled")) w++; if ($4 == "green" && $2 == "false" && toupper($3) != "CONFLICTING") g = 1 }
    END { if (seen && (g || w)) print w + un; else print 0 }'
}

# round_alone_line PICK OUTSTANDING: the one line a pull request that lands
# ahead of its round carries, or nothing when it does not.
round_alone_line() {
  [ "${2:-0}" -gt 0 ] || return 0
  printf 'Landing alone: the rest of its round is still being built.\n'
}

# round_read OPEN: read the running round and set, for this drain round,
#   round_pool_list   OPEN narrowed to the round's members (or OPEN)
#   round_out         how many members it still waits for
#   round_hold        "yes" while it waits and one or more are green
# QUEUE_ROUND=off ignores rounds. A marker that cannot be read is no round.
round_read() {
  round_pool_list=$1; round_out=0; round_hold=""
  [ "${QUEUE_ROUND:-}" = off ] && return 0
  rr_text=${QUEUE_ROUND_COMMENTS:-}
  if [ -z "$rr_text" ]; then
    rr_text=$(gh api --paginate "repos/{owner}/{repo}/issues/${QUEUE_DRIVE_ISSUE:-1}/comments?per_page=100" \
      --jq '.[] | select(.body | contains("sipnship-proposal {\"status\":\"started\"")) | .body | split("\n")[] | select(contains("sipnship-proposal {\"status\":\"started\""))' 2>/dev/null) || rr_text=""
  fi
  rr_parsed=$(round_parse "$(round_marker "$rr_text")")
  [ -n "$rr_parsed" ] || return 0
  rr_prs=$(printf '%s' "$rr_parsed" | cut -f1); rr_un=$(printf '%s' "$rr_parsed" | cut -f2)
  [ -n "$rr_prs" ] || return 0
  round_pool_list=$(round_pool "$1" "$rr_prs")
  round_out=$(round_outstanding "$round_pool_list" "$rr_prs" "$rr_un")
  [ "$round_out" -gt 0 ] && round_hold=yes
  return 0
}

# round_alone_say N PICK: say the line when the drain lands ahead of its
# round, and leave it on the pull request when it is one, so its comment
# carries it.
round_alone_say() {
  [ "$1" = 1 ] || return 0
  ras_line=$(round_alone_line "$2" "${round_out:-0}")
  [ -n "$ras_line" ] || return 0
  say "$ras_line"
  gh_write api -X POST "repos/{owner}/{repo}/issues/$(printf '%s' "$2" | tr -d ' \n')/comments" -f body="$ras_line" >/dev/null 2>&1 || true
}
