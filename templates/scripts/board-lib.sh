#!/bin/sh
# Shared gh calls for the board scripts. Sourced by state.sh and
# board-sync.sh. The pure mappings live in scripts/ci/lib.sh.
# Needs gh signed in with the project scope: gh auth refresh -s project

here_lib=$(dirname "$0")
. "$here_lib/ci/lib.sh"

ALL_STATE_LABELS="state:ready state:in-progress state:waiting-on-owner state:waiting-on-service state:parked state:dated state:after-launch state:blocked"

# gh_project ARGS...: the gh project command, with a retry when GitHub
# refuses the call. Projects v2 has no REST API, so these calls spend
# GraphQL points and trip its secondary limit first; a burst of issue
# closes once started ten of them in two seconds. On a refusal, wait 30,
# 60 then 120 seconds and say which limit it was, then give up with that
# message rather than gh's "unknown owner type".
gh_project() {
  gp_try=0
  while :; do
    if gp_out=$(gh project "$@" 2>&1); then printf '%s\n' "$gp_out"; return 0; fi
    if [ "$(board_refusal "$gp_out")" = no ]; then printf '%s\n' "$gp_out" >&2; return 1; fi
    gp_try=$((gp_try + 1))
    case $gp_try in 1) gp_w=30 ;; 2) gp_w=60 ;; 3) gp_w=120 ;; *)
      echo "GitHub refused the board call for its rate limit three times (gh reports it as \"unknown owner type\"); giving up. The nightly sync will catch up." >&2; return 1 ;;
    esac
    echo "GitHub refused the board call for its rate limit (gh says \"unknown owner type\"); waiting $gp_w seconds." >&2
    sleep "$gp_w"
  done
}

# board_load PROJECT OWNER
# Reads the ids the other functions need into BOARD_* variables.
board_load() {
  BOARD_NUMBER=$1
  BOARD_OWNER=$2
  BOARD_ID=$(gh_project view "$1" --owner "$2" --format json --jq .id)
  BOARD_STATE_FIELD=$(board_fields '.fields[] | select(.name == "State") | .id')
  BOARD_STATUS_FIELD=$(board_fields '.fields[] | select(.name == "Status") | .id')
  [ -n "$BOARD_STATE_FIELD" ] || { echo "Project $1 has no State field; run sh scripts/board.sh first." >&2; exit 1; }
}

# board_fields FILTER: the field list through gh's built-in jq, so nothing
# beyond gh itself is needed.
board_fields() {
  gh_project field-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json --jq "$1"
}

# board_option FIELD_ID NAME -> option id, case-insensitive on the name
board_option() {
  board_fields ".fields[] | select(.id == \"$1\") | .options[] | select((.name | ascii_downcase) == (\"$2\" | ascii_downcase)) | .id"
}

# board_item_for ISSUE_URL -> item id, adding the issue to the board if needed
board_item_for() {
  item=$(gh_project item-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --limit 1000 --format json \
    --jq ".items[] | select(.content.url == \"$1\") | .id")
  if [ -z "$item" ]; then
    item=$(gh_project item-add "$BOARD_NUMBER" --owner "$BOARD_OWNER" --url "$1" --format json --jq .id)
  fi
  printf '%s\n' "$item"
}

# board_set_field ITEM FIELD_ID OPTION_ID
board_set_field() {
  gh_project item-edit --project-id "$BOARD_ID" --id "$1" --field-id "$2" --single-select-option-id "$3" >/dev/null
}

# issue_set_state_label ISSUE LABEL: add this state label, remove the others
issue_set_state_label() {
  isl_cur=$(gh api "repos/{owner}/{repo}/issues/$1/labels" --jq '.[].name' 2>/dev/null || true)
  state_labels_json "$isl_cur" "$2" | gh api -X PUT "repos/{owner}/{repo}/issues/$1/labels" --input - >/dev/null
}

# board_apply ISSUE_NUMBER STATE_NAME CLOSED
# Set the label, the State field and the mirrored Status for one issue.
board_apply() {
  ba_issue=$1
  ba_state=$2
  ba_closed=$3
  ba_label=$(label_from_state_name "$ba_state")
  ba_status=$(status_for "$ba_state" "$ba_closed")
  ba_state_opt=$(board_option "$BOARD_STATE_FIELD" "$ba_state")
  [ -n "$ba_state_opt" ] || { echo "The State field has no value \"$ba_state\"." >&2; return 1; }
  # The label first: it is REST and lands under GitHub's GraphQL limit. The
  # board after it; when GitHub refuses the board call, say the label is
  # set and the board pending, which the nightly sync finishes.
  issue_set_state_label "$ba_issue" "$ba_label"
  ba_url=$(gh api "repos/{owner}/{repo}/issues/$ba_issue" --jq .html_url)
  ba_item=$(board_item_for "$ba_url")
  if [ -z "$ba_item" ] || ! board_set_field "$ba_item" "$BOARD_STATE_FIELD" "$ba_state_opt"; then
    echo "issue $ba_issue: $ba_label set; the board's State is pending (GitHub refused the board call). The nightly board sync sets it; nothing else to do."
    return 0
  fi
  if [ -n "$BOARD_STATUS_FIELD" ]; then
    ba_status_opt=$(board_option "$BOARD_STATUS_FIELD" "$ba_status")
    [ -n "$ba_status_opt" ] && board_set_field "$ba_item" "$BOARD_STATUS_FIELD" "$ba_status_opt"
  fi
  echo "issue $ba_issue: $ba_label, State = $ba_state, Status = $ba_status"
}
