#!/bin/sh
# Open the red-main issue, or add a red run of main to the open one, whatever
# job was red: a failed test, a run red with no failed job, a run that did
# not finish. The comment says which kind it was (gate-lib.sh: red_kind).
#   sh scripts/ci/report-red.sh result GATE FULL TESTS RUN_ID SHA
#       the run's own jobs' results: report it when it was red
#   sh scripts/ci/report-red.sh early
#       the newest scheduled gate ended red before its tests started (so no
#       job of its own could say so): report it once, and say when it is the
#       second in a row. The next hourly gate runs the check once more.
# Needs GH_TOKEN and GH_REPO; REST for reading, `gh issue create` once.
here=$(dirname "$0")
. "$here/gate-lib.sh"
repo=${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
server=${GITHUB_SERVER_URL:-https://github.com}

# say KIND RUN_ID SHA SECOND: open the issue or comment, once for a run.
say() {
  url="$server/$repo/actions/runs/$2"
  note=$(red_note "$1" "$3" "$url" "$4")
  open=$(gh api "repos/$repo/issues?labels=ci-red&state=open&per_page=1" --jq '.[0].number // ""' 2>/dev/null | tr -d '\r')
  if [ -z "$open" ]; then
    gh issue create --title "main is red" --label "ci-red,state:ready" --body "$note"
    return
  fi
  if gh api "repos/$repo/issues/$open/comments?per_page=100" --jq '.[].body' 2>/dev/null | grep -qF "$url"; then
    echo "Run $2 is already on the red-main issue #$open."; return
  fi
  gh api "repos/$repo/issues/$open/comments" -f body="$note" >/dev/null
  echo "Added run $2 to the open red-main issue #$open."
}

case "$1" in
  result)
    kind=$(red_kind "$2" "$3" "$4")
    [ -n "$kind" ] || { echo "Run $5 was not red."; exit 0; }
    say "$kind" "$5" "$6" no ;;
  early)
    count=$(sh "$here/gate.sh" early-red-count)
    [ "${count:-0}" -ge 1 ] || { echo "No gate ended red before its tests."; exit 0; }
    run=$(sh "$here/gate.sh" early-red-run)
    [ -n "$run" ] || exit 0
    second=no; [ "$count" -ge 2 ] && second=yes
    say nostart "$run" "$(gh api "repos/$repo/actions/runs/$run" --jq .head_sha 2>/dev/null | tr -d '\r')" "$second" ;;
  *) echo "usage: report-red.sh result GATE FULL TESTS RUN_ID SHA | early" >&2; exit 2 ;;
esac
