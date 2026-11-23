#!/bin/sh
# How the plan reads the files an issue touches (specs/010-work, "The drive
# plans rounds by files"): the list its first line gives, or a guess from its
# text when it gives none. Pure, text in and text out; needs bundle-lib.sh
# (body_paths, changed_paths, mocks_files, spec_areas). tests/run.sh covers each.

# listed_files BODY
# The comma-separated, sorted, unique paths a body's first line lists when it
# reads "Touches: PATH PATH ...": the issue's own word on the files it
# changes. The list ends at the first word that is no path (one with no slash
# and no file extension). Nothing when the first line is not a Touches line.
listed_files() {
  printf '%s\n' "$1" | tr -d '\r' | awk 'NR == 1 {
    s = $0; sub(/^[ \t]+/, "", s)
    if (s !~ /^Touches:/) exit
    s = substr(s, 9); gsub(/[`,;()<>"]/, " ", s)
    n = split(s, w, /[ \t]+/)
    for (i = 1; i <= n; i++) {
      t = w[i]; if (t == "") continue
      sub(/[.:!?]+$/, "", t); sub(/^\.\//, "", t)
      if (t !~ /\// && t !~ /\.[A-Za-z0-9]+$/) break
      if (t ~ /^specs\/[0-9]+-[A-Za-z0-9_-]+$/) t = t "/"
      print t
    }
    exit
  }' | sort -u | paste -sd, -
}

# guess_files BODY MOCKS PAST
# The comma-separated, sorted, unique files an issue is guessed to touch.
# An issue whose first line lists its files (listed_files) touches those and
# nothing more: no path its prose mentions, no spec its Spec line names, no
# spec history and no mock is added, so it is never held for a file it does
# not list (#2444). Only an issue with no list is guessed: the paths its body
# names, the files of any mocks line they hit, and the past files of any spec
# it names. PAST is past_spec_files' output. Prints nothing when the body
# names no path.
guess_files() {
  gf_listed=$(listed_files "$1")
  if [ -n "$gf_listed" ]; then printf '%s\n' "$gf_listed"; return 0; fi
  gf_paths=$(changed_paths "$(body_paths "$1")")
  if [ -z "$gf_paths" ]; then
    # No path named, but plugin or CI work still shares one test suite: an issue that speaks of the plugin, the drive skill, a workflow, the queue's drain or a check of the CI is guessed as plugin/, so it goes into the one bundle (#1879).
    if printf '%s\n' "$1" | grep -qiE '(^|[^a-z])(plugin|project-drive|publish-round|plan\.sh|drive(.s)? (plan|round|script|skill)s?|[a-z0-9_-]+\.ya?ml|(github )?workflows?|github actions|queue[- ]drain|merge[- ]queue|scheduled (deploy|drain|queue)|deploy (run|job)s?|ci (jobs?|checks?|scripts?)|checks? (job|step)s?|[a-z-]+-check\.sh|scripts/ci|\.github)([^a-z]|$)'; then printf 'plugin/\n'; fi
    return 0
  fi
  {
    printf '%s\n' "$gf_paths"
    mocks_files "$gf_paths" "$2"
    for gf_s in $(spec_areas "$gf_paths"); do
      printf '%s/\n' "$gf_s"
      printf '%s\n' "$3" | awk -F'\t' -v s="$gf_s" '$1 == s { print $2 }'
    done
  } | sed '/^$/d' | sort -u | paste -sd, -
}

# plan_issue_text
# For the issue plan.sh is reading (title, c, d, e: its title, the start of its
# body, the paths of its whole text and its Touches column): sets issue_text,
# the text guess_files reads, with the Touches line first when there is one,
# and adds num to plan_listed, both the caller's own globals. A function, not a
# subshell, so no process is started per issue.
plan_issue_text() {
  issue_text="$title $c $d"
  [ -n "$e" ] || return 0
  issue_text="Touches: $e
$issue_text"
  plan_listed="$plan_listed $num"
}
