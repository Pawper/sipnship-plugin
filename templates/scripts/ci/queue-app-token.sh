#!/bin/sh
# Mints the queue App's installation token with openssl and curl alone, so no
# outside action ever holds the key. Prints the token on standard output and
# nothing else; says why on standard error and prints nothing when the App is
# not set up (QUEUE_APP_ID and QUEUE_APP_KEY unset), so a workflow falls back
# to QUEUE_TOKEN. Exit 0 when not configured, 1 when configured but the host
# refused. The key is read from the environment, written to a private temp
# file only while openssl signs, and never printed.
#   env: QUEUE_APP_ID, QUEUE_APP_KEY, GH_REPO (owner/name), API_URL
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

[ -n "${QUEUE_APP_ID:-}" ] && [ -n "${QUEUE_APP_KEY:-}" ] || { echo "No queue App is set up; using QUEUE_TOKEN." >&2; exit 0; }
api=${QUEUE_APP_API:-${GITHUB_API_URL:-https://api.github.com}}
repo=${GH_REPO:-${GITHUB_REPOSITORY:-}}
[ -n "$repo" ] || { echo "The repository is not named (GH_REPO)." >&2; exit 1; }

umask 077
tmp=$(mktemp -d 2>/dev/null) || { tmp=${RUNNER_TEMP:-.}/qat.$$; mkdir -p "$tmp"; }
keyfile="$tmp/key.pem"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$QUEUE_APP_KEY" > "$keyfile"

now=${QUEUE_APP_NOW:-$(date +%s)}
head=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
body=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$QUEUE_APP_ID" | b64url)
sig=$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -sign "$keyfile" -binary 2>/dev/null | b64url)
[ -n "$sig" ] || { echo "The queue App's key could not sign; check QUEUE_APP_KEY." >&2; exit 1; }
jwt="$head.$body.$sig"

get() { printf 'Authorization: Bearer %s\n' "$jwt" | curl -s --max-time 20 -H @- -H 'Accept: application/vnd.github+json' "$@"; }
inst=$(get "$api/repos/$repo/installation" | sed -n 's/^[[:space:]]*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$inst" ] || { echo "The queue App is not installed on $repo." >&2; exit 1; }
token=$(get -X POST "$api/app/installations/$inst/access_tokens" | sed -n 's/.*"token":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$token" ] || { echo "The queue App was not given a token." >&2; exit 1; }
printf '%s\n' "$token"
