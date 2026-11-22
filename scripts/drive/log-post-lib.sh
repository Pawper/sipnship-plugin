#!/bin/sh
# One way a log line reaches a project's standing issue (the drive's, the
# audit's or the merge queue's) from this machine (#2308, spec 005, "The log
# issues' author"). Where the project is connected to the service, the line is
# posted through the service as the app, so the builder is not its author and
# GitHub does not email them for it. Where it is not, or the service does not
# take the line, it is posted as before, with the builder's own gh sign-in, and
# a failed call says so in one line: a log line is never lost. Sourced by
# handoff.sh and publish-round.sh. Needs curl and node for the service path;
# with either missing it posts as before, silently, as a project with only the
# free plugin always does.

# log_post KIND ISSUE FILE
# KIND is drive, audit or queue; ISSUE the number of that log's issue; FILE
# holds the line. Prints the link to the comment (the gh path) or the issue's
# own link (the service path), and returns 1 when neither path took the line.
log_post() {
  lp_kind=$1; lp_issue=$2; lp_file=$3
  if lp_via_service "$lp_kind" "$lp_file"; then
    echo "https://github.com/$(lp_repo)/issues/$lp_via_issue"
    return 0
  fi
  [ -z "$lp_service_say" ] || echo "$lp_service_say" >&2
  gh api -X POST "repos/{owner}/{repo}/issues/$lp_issue/comments" -F "body=@$lp_file" --jq .html_url
}

# lp_repo: this checkout's owner/name, from its origin remote.
lp_repo() {
  git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//'
}

# lp_via_service KIND FILE
# Posts through the service. Returns 0 and sets lp_via_issue when it took the
# line; returns 1 with lp_service_say empty when this project is not connected
# (nothing to say: the plugin-only path is the normal one), and with
# lp_service_say holding the one line to print when it is connected and the
# call failed.
lp_via_service() {
  lp_service_say=""; lp_via_issue=""
  [ -f scripts/ci/service-auth.sh ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v node >/dev/null 2>&1 || return 1
  [ -n "${QUEUE_SERVICE_AUTH_LOADED:-}" ] || { . scripts/ci/service-auth.sh; QUEUE_SERVICE_AUTH_LOADED=1; }
  service_sign_in || return 1
  lp_json=$(node -e 'process.stdout.write(JSON.stringify({ kind: process.argv[1], body: require("fs").readFileSync(process.argv[2], "utf8") }))' "$1" "$2" 2>/dev/null)
  [ -n "$lp_json" ] || return 1
  lp_out=$(printf 'Authorization: Bearer %s\n' "$sv_token" | curl -s --max-time 15 -w '\n%{http_code}' -X POST -H @- -H 'content-type: application/json' --data "$lp_json" "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$sv_id/log-comment" 2>/dev/null)
  lp_code=$(printf '%s' "$lp_out" | tail -n 1 | tr -d '\r')
  if [ "$lp_code" = 201 ]; then
    lp_via_issue=$(printf '%s' "$lp_out" | sed '$d' | node -e 'let r="";process.stdin.on("data",d=>r+=d);process.stdin.on("end",()=>{try{const n=JSON.parse(r).issue;if(Number.isInteger(n))process.stdout.write(String(n))}catch{}})' 2>/dev/null)
    [ -n "$lp_via_issue" ] && return 0
  fi
  lp_service_say="The service did not take the log line, so it is posted with your own sign-in instead."
  return 1
}
