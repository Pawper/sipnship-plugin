#!/bin/sh
# Every caller counted, not only the service (#2863): this machine's own tally of GitHub calls
# (hooks/scripts/budget-rest-lib.sh, budget_history_add) is summed by kind since the last send and posted,
# one kind a line, to the SipNShip service (POST /v1/repos/{id}/spend/github), so Cost shows the drive, the
# agents and check polling beside the app's own reads. The send is never a gate: a repository that cannot
# sign in, or a send that fails, is skipped quietly and the same counts are picked up again next time; this
# script makes no call to GitHub itself, so it never spends what it is counting.
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/spend-send.sh"
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/../../hooks/scripts/budget-rest-lib.sh"
[ -f "$here/../../templates/scripts/ci/service-auth.sh" ] && . "$here/../../templates/scripts/ci/service-auth.sh"
type service_sign_in >/dev/null 2>&1 || exit 0
service_sign_in || exit 0

log=$(budget_history_file)
mark="$log.sent"
since=$(cat "$mark" 2>/dev/null | tr -d '\r'); case "$since" in ''|*[!0-9]*) since=0 ;; esac
now=$(date +%s)
counts=$(budget_spend_by_kind "$log" "$since")
tab=$(printf '\t')
if [ -n "$counts" ]; then
  printf '%s\n' "$counts" | while IFS="$tab" read -r ss_kind ss_calls; do
    [ -n "$ss_kind" ] && [ -n "$ss_calls" ] || continue
    ss_body=$(printf '{"caller":"%s","calls":%s}' "$ss_kind" "$ss_calls")
    printf 'Authorization: Bearer %s\n' "$sv_token" \
      | curl -s -o /dev/null --max-time 5 -X POST -H @- -H 'content-type: application/json' --data-binary "$ss_body" \
        "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$sv_id/spend/github" >/dev/null 2>&1 || true
  done
fi
mkdir -p "$(dirname "$mark")" 2>/dev/null
printf '%s\n' "$now" > "$mark" 2>/dev/null
exit 0
