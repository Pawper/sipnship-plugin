#!/bin/sh
# One way an agent's note on an ordinary issue reaches it from this machine
# (#2486, spec 022, "How an ask reaches the builder"). Where the project is
# connected to the service, the note is posted through the service as the app,
# marked with the agent that wrote it, and it never names the builder, so
# GitHub emails no one for it; the service follows up on an ask, once, by name.
# Where it is not connected, it is posted with the builder's own gh sign-in as
# before, silently; where it is connected and the service does not take the
# note, it is posted as before and says so in one line: a note is never lost.
# Sourced by comment.sh. Needs curl and node for the service path; with either
# missing it posts as before, silently, as a project with only the free plugin
# always does.

# note_post ISSUE FILE
# Prints the link to the comment (the gh path) or the issue's own link (the
# service path), and returns 1 when neither path took the note.
note_post() {
  np_issue=$1; np_file=$2
  if np_via_service "$np_issue" "$np_file"; then
    echo "https://github.com/$(np_repo)/issues/$np_issue"
    return 0
  fi
  [ -z "$np_service_say" ] || echo "$np_service_say" >&2
  gh api -X POST "repos/{owner}/{repo}/issues/$np_issue/comments" -F "body=@$np_file" --jq .html_url
}

# np_repo: this checkout's owner/name, from its origin remote.
np_repo() {
  git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//'
}

# np_is_ask FILE: succeeds when the note is a question waiting on the builder,
# a choice marked "Recommended." or marked instructions, as the service reads one.
np_is_ask() {
  grep -Eq '(^|[^A-Za-z])Recommended\.|^Instructions:' "$1" 2>/dev/null
}

# np_via_service ISSUE FILE
# Returns 0 when the service took the note; returns 1 with np_service_say empty
# when this project is not connected, and with np_service_say holding the one
# line to print when it is connected and the call failed. The agent's name is
# SIPNSHIP_AGENT when the session sets it, else "an agent".
np_via_service() {
  np_service_say=""
  [ -f scripts/ci/service-auth.sh ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v node >/dev/null 2>&1 || return 1
  [ -n "${QUEUE_SERVICE_AUTH_LOADED:-}" ] || { . scripts/ci/service-auth.sh; QUEUE_SERVICE_AUTH_LOADED=1; }
  service_sign_in || return 1
  np_ask=false; np_is_ask "$2" && np_ask=true
  np_json=$(node -e 'process.stdout.write(JSON.stringify({ issue: Number(process.argv[1]), body: require("fs").readFileSync(process.argv[2], "utf8"), agent: process.argv[3], ask: process.argv[4] === "true" }))' "$1" "$2" "${SIPNSHIP_AGENT:-an agent}" "$np_ask" 2>/dev/null)
  [ -n "$np_json" ] || return 1
  np_out=$(printf 'Authorization: Bearer %s\n' "$sv_token" | curl -s --max-time 15 -w '\n%{http_code}' -X POST -H @- -H 'content-type: application/json' --data "$np_json" "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$sv_id/issue-note" 2>/dev/null)
  np_code=$(printf '%s' "$np_out" | tail -n 1 | tr -d '\r')
  [ "$np_code" = 201 ] && return 0
  np_service_say="The service did not take the note, so it is posted with your own sign-in instead."
  return 1
}
