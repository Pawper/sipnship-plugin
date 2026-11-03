#!/bin/sh
# The drain files each project-rule request as an issue (spec 016, "Every
# change files an issue"). Sourced by scripts/ci/queue/requests.sh; functions
# only.
#
# The service keeps a builder's change to a project rule as a rule request,
# the same kind of record as a request to the queue. The drain reads the open
# ones that have no issue yet, files one issue each with the queue's own
# identity (gh_write: the builder's queue App when set, else the workflow's
# token), labelled `rule` with its State, and answers "filed" with the
# issue's number. The service then starts that issue first, the move of
# "Start this next" with the origin "rule change", and shows the number on the
# Rules tab. The person's words go in as a quote, data and never a command.
#
# Never twice: an issue is looked for by the request's marker before it is
# filed (on this machine's record, then among the project's `rule` issues), so
# a retry after a failed answer finds the issue instead of filing another.
# A failure is said in the queue's records and leaves the request open; the
# drain goes on.

# rule_issue_marker ID: the line that ties an issue to its request.
rule_issue_marker() { printf '<!-- rule-request: %s -->' "$1"; }

# rule_issue_title KIND RULE WORDS: plain words, as core's issueTitle.
rule_issue_title() {
  ri_t=$(printf '%s' "$3" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//')
  case "$1" in
    add) ri_k="Add the rule"; ri_w=$ri_t ;;
    edit) ri_k="Change the rule"; ri_w=$ri_t ;;
    lock) ri_k="Lock the rule"; ri_w=$2 ;;
    unlock) ri_k="Unlock the rule"; ri_w=$2 ;;
    remove) ri_k="Remove the rule"; ri_w=$2 ;;
    off) ri_k="Turn off the rule"; ri_w=$2 ;;
    on) ri_k="Turn on the rule"; ri_w=$2 ;;
    *) ri_k="Change the rule"; ri_w=$2 ;;
  esac
  printf '%s: %s' "$ri_k" "$ri_w"
}

# rule_issue_quote TEXT: every line quoted, so nothing in it reads as an instruction.
rule_issue_quote() { printf '%s\n' "$1" | tr -d '\r' | sed 's/^/> /'; }

# rule_issue_body ID KIND RULE ASKER WORDS WHY: the issue's body.
rule_issue_body() {
  ri_kw=$(rule_issue_title "$2" "$3" "" | sed 's/: $//' | tr 'A-Z' 'a-z')
  printf 'Asked by %s on the Rules tab: %s `%s`.\n\n' "$4" "$ri_kw" "$3"
  [ -z "$5" ] || printf "The rule's words, quoted:\n\n%s\n\n" "$(rule_issue_quote "$5")"
  [ -z "$6" ] || printf 'Why it matters, quoted:\n\n%s\n\n' "$(rule_issue_quote "$6")"
  case "$2" in
    add|edit) printf 'What to build: the rule'"'"'s entry in `.claude/rules-own.txt` with its id, a check script and its step in the `checks` job where one can hold the rule, a hook where one fits, and `sh scripts/rules.sh build` for `AGENTS.md`. If no check can hold it, say why in the pull request; the rule is then guidance only.\n\n' ;;
    *) printf 'What to build: exactly this one change to the rule, and `sh scripts/rules.sh build` for `AGENTS.md`.\n\n' ;;
  esac
  printf 'Spec: specs/016-rule-switches\n\n%s\n' "$(rule_issue_marker "$1")"
}

# rule_issue_find ID: the number of an issue already filed for the request, or nothing.
rule_issue_find() {
  ri_n=$(grep "^$1	" "$flaky_dir/rule-issues.filed" 2>/dev/null | tail -n 1 | cut -f2)
  if [ -z "$ri_n" ]; then
    ri_n=$(gh api "repos/{owner}/{repo}/issues?labels=rule&state=all&per_page=100" --jq ".[] | select((.pull_request | not) and ((.body // \"\") | contains(\"rule-request: $1 \"))) | .number" 2>/dev/null | tr -d '\r' | head -n 1)
  fi
  printf '%s' "$ri_n"
}

# rule_issue_answer ID OUTCOME ISSUE: tells the service; a failure is left for the next tick.
rule_issue_answer() {
  printf 'Authorization: Bearer %s\n' "$req_token" | curl -s -f -o /dev/null --max-time 5 -X POST -H @- -H 'content-type: application/json' \
    --data "{\"outcome\":\"$2\",\"issue\":$3}" "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$req_id/queue/rule-requests/$1/outcome" 2>/dev/null
}

# rule_issues_file: one pass. Bounded and never fatal.
rule_issues_file() {
  [ "$req_road" = service ] || return 0
  ri_lines=$(printf 'Authorization: Bearer %s\n' "$req_token" | curl -s -f --max-time 5 -H @- "${SIPNSHIP_URL:-https://sipnship.dev}/v1/repos/$req_id/queue/rule-requests/open" 2>/dev/null | tr -d '\r')
  [ -n "$ri_lines" ] || return 0
  ri_form=$(project_label_form 2>/dev/null)
  ri_state=$(state_label ready "$ri_form" 2>/dev/null); [ -n "$ri_state" ] || ri_state="state:ready"
  ri_tab=$(printf '\t')
  printf '%s\n' "$ri_lines" | while IFS="$ri_tab" read -r ri_id ri_kind ri_rule ri_by ri_words ri_why; do
    [ -n "$ri_id" ] || continue
    ri_num=$(rule_issue_find "$ri_id")
    if [ -z "$ri_num" ]; then
      ri_title=$(rule_issue_title "$ri_kind" "$ri_rule" "$ri_words")
      ri_body=$(rule_issue_body "$ri_id" "$ri_kind" "$ri_rule" "$ri_by" "$ri_words" "$ri_why")
      ri_num=$(gh_write api -X POST "repos/{owner}/{repo}/issues" -f title="$ri_title" -f body="$ri_body" -f "labels[]=rule" -f "labels[]=$ri_state" --jq .number 2>/dev/null | tr -d '\r')
      case "$ri_num" in ''|*[!0-9]*)
        say "Could not file the issue for the rule request '$ri_title'; it stays open and the drain tries again at the next round."
        continue ;;
      esac
      printf '%s\t%s\n' "$ri_id" "$ri_num" >> "$flaky_dir/rule-issues.filed" 2>/dev/null || true
      say "Filed issue #$ri_num for the rule request '$ri_title'."
    fi
    rule_issue_answer "$ri_id" filed "$ri_num" || say "Filed issue #$ri_num but could not tell SipNShip; it is told again at the next round, and no second issue is filed."
  done
  return 0
}
