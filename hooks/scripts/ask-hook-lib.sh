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
# The verdict of the ask an issue would be shown with if it were set to
# waiting on the owner now: the newest comment that carries an ask, posted in
# the last ten minutes (whoever sets the state comments first, and an older
# comment is not this wait's reason). One REST call. Prints nothing when
# GitHub cannot be asked, so a hook never refuses on a failed read.
ask_of_issue() {
  # Comments touched in the last ten minutes, so a long issue's newest are read in one page.
  ao_since=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  ao_out=$(gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100${ao_since:+&since=$ao_since}" \
    --jq "[.[] | select((.created_at | fromdateiso8601) >= (now - 600))] | reverse | .[] | .body, \"$ASK_NEXT\"" 2>/dev/null) || return 0
  printf '%s\n' "$ao_out" | ask_verdict
}
