#!/bin/sh
# How the queue signs in to the SipNShip service. Sourced by publish-state.sh
# and queue/requests.sh; functions only.
#
# service_sign_in sets sv_token and sv_id (the repository's numeric GitHub id)
# and returns 0, or returns 1 when there is no way to sign in:
#   1. In a workflow with `id-token: write`, GitHub's own identity token for
#      this run, asked for with the audience https://sipnship.dev. No secret
#      is pasted anywhere; the token is short-lived, so it is asked for again
#      at each use and never kept.
#   2. On a machine, the token `npx sipnship connect --repo` kept in
#      ~/.sipnship/tokens.json (or $SIPNSHIP_HOME).
#   SIPNSHIP_REPO_TOKEN and SIPNSHIP_REPO_ID, when set, win: a local override.
SERVICE_AUDIENCE="https://sipnship.dev"
service_sign_in() {
  sv_token=${SIPNSHIP_REPO_TOKEN:-}; sv_id=${SIPNSHIP_REPO_ID:-}
  if [ -z "$sv_token" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
    sv_token=$(printf 'Authorization: Bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" | curl -s --max-time 5 -H @- "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$SERVICE_AUDIENCE" 2>/dev/null | sed -n 's/.*"value":"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$sv_id" ] || sv_id=${GITHUB_REPOSITORY_ID:-}
  fi
  if [ -z "$sv_token" ] && command -v node >/dev/null 2>&1; then
    sv_repo=$(git remote get-url origin 2>/dev/null | tr -d '\r' | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/]*\)$#\1/\2#p' | sed 's/\.git$//')
    sv_pair=$(node -e '
      const fs = require("fs"), path = require("path"), os = require("os");
      const home = process.env.SIPNSHIP_HOME || path.join(os.homedir(), ".sipnship");
      try {
        const repos = JSON.parse(fs.readFileSync(path.join(home, "tokens.json"), "utf8")).repos || {};
        for (const [id, e] of Object.entries(repos)) if (e && String(e.fullName).toLowerCase() === process.argv[1].toLowerCase()) { process.stdout.write(id + "\t" + e.token); break; }
      } catch {}' "$sv_repo" 2>/dev/null)
    if [ -n "$sv_pair" ]; then sv_id=${sv_pair%%	*}; sv_token=${sv_pair#*	}; fi
  fi
  [ -n "$sv_token" ] || return 1
  [ -n "$sv_id" ] || { sv_id=$(gh api "repos/{owner}/{repo}" --jq .id 2>/dev/null | tr -d '\r'); }
  [ -n "$sv_id" ] || return 1
  command -v curl >/dev/null 2>&1
}
