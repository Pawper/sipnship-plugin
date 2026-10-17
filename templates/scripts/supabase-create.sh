#!/bin/sh
# Create this app's Supabase project in one approved command. It generates
# the database password, creates the project in the organization, writes
# the password and the project reference into .env and nowhere else, and
# prints no secret. The console's database card turns ready once the
# database address is set from them.
#
# Usage: sh scripts/supabase-create.sh NAME [REGION]
#   NAME    the project name on Supabase (the app's name)
#   REGION  default us-east-1
# Needs the supabase CLI, signed in (supabase login). The organization is
# SUPABASE_ORG_ID when set, else the first organization the account has.
# --size is never passed: the free plan refuses it.
set -e
here=$(dirname "$0")
. "$here/env-lib.sh"

name=$1
region=${2:-us-east-1}
[ -n "$name" ] || { echo "Usage: sh scripts/supabase-create.sh NAME [REGION]" >&2; exit 2; }
command -v supabase >/dev/null 2>&1 || { echo "The supabase CLI is not installed; see https://supabase.com/docs/guides/cli" >&2; exit 2; }

org=${SUPABASE_ORG_ID:-}
if [ -z "$org" ]; then
  org=$(supabase orgs list -o json 2>/dev/null | tr -d '\r\n' | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -n 1)
fi
[ -n "$org" ] || { echo "No Supabase organization found; sign in with supabase login, or set SUPABASE_ORG_ID." >&2; exit 2; }

password=$(random_password 32)
out=$(supabase projects create "$name" --org-id "$org" --region "$region" --db-password "$password" -o json 2>&1) || {
  echo "Supabase refused to create the project:" >&2
  printf '%s\n' "$out" | sed "s/$password/[password]/g" >&2
  exit 1
}
ref=$(printf '%s' "$out" | tr -d '\r\n' | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -n 1)

env_file=.env
text=""; [ -f "$env_file" ] && text=$(cat "$env_file")
text=$(env_set "$text" SUPABASE_DB_PASSWORD "$password")
[ -n "$ref" ] && text=$(env_set "$text" SUPABASE_PROJECT_REF "$ref")
[ -n "$ref" ] && text=$(env_set "$text" SUPABASE_URL "https://$ref.supabase.co")
printf '%s\n' "$text" > "$env_file"
chmod 600 "$env_file" 2>/dev/null || true

echo "Created the Supabase project $name${ref:+ ($ref)} in $region. Its database password and reference are in $env_file and nowhere else."
echo "Next: set DATABASE_URL from the project's connection string (Settings, Database) in $env_file, and add the line to SETUP.md."
