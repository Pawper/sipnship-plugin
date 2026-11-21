#!/bin/sh
# The hook side of "an ask with choices recommends exactly one": which
# command puts an issue in front of the owner, and what its ask says.
# Sourced by require-state-label.sh after lib.sh; what counts as an ask lives
# in templates/scripts/ci/ask-lib.sh, shared with the nightly audit.

# waiting_on_owner_issue COMMAND
# Print the number of the issue a command sets to waiting on the owner, or
# nothing. Three forms: gh issue edit N --add-label state:waiting-on-owner,
# the REST form (gh api .../issues/N/labels with labels[]=state:waiting-on-owner),
# and the project's own script (sh scripts/state.sh PROJECT OWNER N "Waiting on owner").
# A label in either form, state:waiting-on-owner or state: waiting-on-owner.
waiting_on_owner_issue() {
  split_commands "$(printf '%s' "$1" | sed 's/{owner}/OWNER/g; s/{repo}/REPO/g')" | awk '
    function num(s) { sub(/^#/, "", s); sub(/.*\/issues\//, "", s); return s ~ /^[0-9]+$/ ? s : "" }
    {
      line = $0; gsub(/["\x27]/, "", line)
      n = split(line, t, /[ \t]+/)
      first = t[1]; sub(/.*[\/\\]/, "", first)
      waiting = (tolower(line) ~ /state:[ \t]*waiting-on-owner/)
      if (first == "gh" && t[2] == "issue" && t[3] == "edit" && waiting) {
        rest = line; adds = 0
        while (match(rest, /(^|[ \t])--add-label(=|[ \t]+)/)) {
          rest = substr(rest, RSTART + RLENGTH); value = rest
          if (match(value, /[ \t]-/)) value = substr(value, 1, RSTART - 1)
          if (tolower(value) ~ /state:[ \t]*waiting-on-owner/) adds = 1
        }
        if (!adds) next
        for (j = 4; j <= n; j++) if (num(t[j]) != "" && t[j - 1] !~ /^-/) { print num(t[j]); exit }
        next
      }
      if (first == "gh" && t[2] == "api" && waiting) {
        get = 0
        for (j = 3; j <= n; j++) {
          if ((t[j] == "-X" || t[j] == "--method") && toupper(t[j + 1]) ~ /^(GET|DELETE)$/) get = 1
          if (t[j] ~ /^--method=/ && toupper(substr(t[j], 10)) ~ /^(GET|DELETE)$/) get = 1
        }
        if (get) next
        for (j = 3; j <= n; j++) if (match(t[j], /issues\/[0-9]+\/labels/)) {
          s = substr(t[j], RSTART + 7, RLENGTH - 14); print s; exit
        }
        next
      }
      if ((first == "sh" || first == "bash") && t[2] ~ /(^|\/)state\.sh$/ && t[5] ~ /^[0-9]+$/) {
        name = ""
        for (j = 6; j <= n; j++) name = name " " t[j]
        name = tolower(name); gsub(/-/, " ", name)
        if (name ~ /^ *waiting on (the )?owner *$/) { print t[5]; exit }
      }
    }'
}

# ask_of_issue NUMBER
# ask_check's word for the ask an issue would be shown with if it were set to
# waiting on the owner now: the newest comment that carries an ask, posted in
# the last ten minutes (whoever sets the state comments first, and an older
# comment is not this wait's reason); "none" when there is none, which is
# refused too. One REST call. Prints nothing when GitHub cannot be asked, so a
# hook never refuses on a failed read.
ask_of_issue() {
  # Comments touched in the last ten minutes, so a long issue's newest are read in one page.
  ao_since=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  ao_out=$(hook_bounded "${HOOK_NET_SECONDS:-5}" gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100${ao_since:+&since=$ao_since}" \
    --jq "[.[] | select((.created_at | fromdateiso8601) >= (now - 600))] | reverse | .[] | .body, \"$ASK_NEXT\"" 2>/dev/null) || return 0
  ao_verdict=$(printf '%s\n' "$ao_out" | ask_check)
  case "$ao_verdict" in
    one) ask_scope "$1" "$(printf '%s\n' "$ao_out" | ask_question)" ;;
    *) printf '%s\n' "$ao_verdict" ;;
  esac
}

# ask_question
# The question line of the newest comment that carries numbered choices, read
# from comments separated by $ASK_NEXT: the last non-empty line that ends in a
# question mark before its first "1." choice. Nothing when there is none.
ask_question() {
  awk -v next_line="$ASK_NEXT" '
    function flush() { if (!done && q != "" && seen) { print q; done = 1 } q = ""; seen = 0; stop = 0 }
    { sub(/\r$/, "") }
    $0 == next_line { flush(); next }
    !stop && /^[ \t]*1[.)]/ { seen = 1; stop = 1; next }
    !stop && /\?[ \t*_]*$/ { q = $0 }
    END { flush() }'
}

# ask_scope ISSUE QUESTION
# "one" when the ask is about its own issue alone; "other" when its question
# names another issue by number; "twice" when the same question was posted on
# a different issue in the last day (a note of each question seen is kept in
# $SIPNSHIP_HOME/asks-seen.txt, a hash and an issue and a time, nothing more).
# Each issue's question is its own: the same text on two issues makes the
# builder review one piece of work twice.
ask_scope() {
  as_q=$2
  if printf '%s' "$as_q" | grep -o '#[0-9][0-9]*' | grep -qv "^#$1\$"; then printf '%s\n' other; return 0; fi
  [ -n "$as_q" ] || { printf '%s\n' one; return 0; }
  as_dir=${SIPNSHIP_HOME:-${HOME:-}/.sipnship}; as_file=$as_dir/asks-seen.txt
  as_key=$(printf '%s' "$as_q" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cksum | cut -d' ' -f1)
  as_now=$(date +%s)
  as_hit=$(awk -F'\t' -v k="$as_key" -v i="$1" -v n="$as_now" '$1 == k && $2 != i && n - $3 < 86400 { print $2; exit }' "$as_file" 2>/dev/null)
  if [ -n "$as_hit" ]; then printf '%s\n' twice; return 0; fi
  if mkdir -p "$as_dir" 2>/dev/null; then
    { awk -F'\t' -v n="$as_now" 'n - $3 < 86400' "$as_file" 2>/dev/null; printf '%s\t%s\t%s\n' "$as_key" "$1" "$as_now"; } > "$as_file.tmp" 2>/dev/null && mv "$as_file.tmp" "$as_file" 2>/dev/null
  fi
  printf '%s\n' one
}
