#!/bin/sh
# The plugin release the plan proposes, read from the remote's main and
# checked against work already underway. Sourced by plan.sh after drive-lib.sh.

# release_ref
# The ref the unreleased plugin commits are counted on: the remote's main after
# a quiet, bounded fetch, so a checkout nobody fast-forwarded proposes the same
# release as a fresh one. Falls back to the local main (or HEAD) when there is
# no remote or the fetch fails; the plan never stops for it.
release_ref() {
  if git remote get-url origin >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then timeout -k 5 30 git fetch -q origin main >/dev/null 2>&1 || true
    else git fetch -q origin main >/dev/null 2>&1 || true; fi
    if git rev-parse --verify -q origin/main >/dev/null 2>&1; then echo origin/main; return 0; fi
  fi
  echo main
}

# plugin_version_at REF
# The plugin's version as REF holds it (the local file when REF has none).
plugin_version_at() {
  pv_json=$(gitb show "$1:plugin/.claude-plugin/plugin.json" 2>/dev/null || cat plugin/.claude-plugin/plugin.json 2>/dev/null)
  json_field "$pv_json" version
}

# published_plugin_version: the public plugin repository's newest published
# tag's version (X.Y.Z), one REST call; nothing when it cannot be read. The
# queue tags a release but makes no GitHub Release object, so this reads
# tags (sorted here, since the API names no order), never releases/latest.
published_plugin_version() {
  gh api "repos/Pawper/sipnship-plugin/tags?per_page=30" --jq '.[].name' 2>/dev/null | tr -d '\r' | sed 's/^plugin-//; s/^v//' | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# newer_plugin_version A B: the greater of two X.Y.Z versions, by ver_lt
# (hooks/scripts/session-brief-versions.sh); either empty passes the other
# through. The release number always comes from the newer of main's own
# version and what is already published, never from main alone, so a main
# that went backwards (a release landed out of order) still gets the next
# number past what readers already see as released (#2052).
newer_plugin_version() {
  if [ -z "$1" ]; then printf '%s\n' "$2"; return 0; fi
  if [ -z "$2" ]; then printf '%s\n' "$1"; return 0; fi
  if [ "$(ver_lt "$1" "$2")" = yes ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

# open_release_issue FACTS VERSION
# FACTS are board-now.sh's lines. Prints "NUMBER<TAB>TITLE" of an open issue,
# in any State, whose title names VERSION and says plugin or release: a unit
# is already making that release (or it waits its turn), so none is proposed.
open_release_issue() {
  [ -n "$2" ] || return 0
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v v="$2" '
    $1 == "issue" && !found {
      s = $3; i = index(s, v); if (!i) next
      c = substr(s, i + length(v), 1)
      if (c ~ /[0-9]/ || (c == "." && substr(s, i + length(v) + 1, 1) ~ /[0-9]/)) next
      if (tolower(s) !~ /(plugin|release)/) next
      print $2 "\t" $3; found = 1
    }'
}

# release_proposal FACTS PULLS
# The one line the plan adds for a plugin release, or nothing: the release goal
# when plugin commits sit unreleased on the remote's main and no open pull
# request or open issue already carries it; an unnumbered hold line naming the
# issue when one does.
release_proposal() {
  rp_ref=$(release_ref)
  rp_ver=$(newer_plugin_version "$(plugin_version_at "$rp_ref")" "$(published_plugin_version)")
  rp_line=$(release_goal "$rp_ver" "$(plugin_unreleased_count "$rp_ref")")
  [ -n "$rp_line" ] || return 0
  rp_next=$(next_patch "$rp_ver")
  rp_pr=$(open_release_pr "$1" "$2" "$rp_next")
  if [ -n "$rp_pr" ]; then
    # An unnumbered line naming the pull request, so a reader sees why no release is proposed (#1873).
    printf 'note: the release of %s is already in pull request %s; no second release is proposed\n' "$rp_next" "$rp_pr"
    return 0
  fi
  rp_issue=$(open_release_issue "$1" "$rp_next")
  if [ -n "$rp_issue" ]; then
    printf 'hold\t%s\t%s\tthe release of %s is already underway\n' "${rp_issue%%	*}" "${rp_issue#*	}" "$rp_next"
    return 0
  fi
  printf '%s\n' "$rp_line"
}

# add_release ROUND LINE
# Put release_proposal's line into a round: a goal as add_goal does, a hold
# line before the defer and stop lines without changing what the stop says.
add_release() {
  case "$2" in
    '') printf '%s\n' "$1" ;;
    hold*|note:*) printf '%s\n' "$1" | awk -v line="$2" '!done && /^(defer|stop:)/ { print line; done = 1 } { print } END { if (!done) print line }' ;;
    *) add_goal "$1" "$2" ;;
  esac
}
