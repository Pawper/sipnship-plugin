#!/bin/sh
# A fix agent never ends with work only in its own checkout (#2260). When the push to the change's branch is refused, it
# pushes the commit to a side branch named for the change and says in one comment what the push waits on, as a thing with
# a number. The drive merges the side branch into the change's branch when that lands (fix-side.sh, no model). Pure: text
# in, text out. Sourced by fix-side.sh and fix-owed.sh.

# fix_side_branch PR: the side branch's name. Never `issue-...`, so the claim does not read it as work, and never a branch
# the queue lands.
fix_side_branch() { printf 'fixside/pr-%s\n' "$1"; }

# fix_push_refusal_kind TEXT: check when the project's own check before a push refused it, github when GitHub did, else
# unknown. The local check names itself in its words; GitHub's refusals come back from the remote.
fix_push_refusal_kind() {
  if printf '%s\n' "$1" | grep -Eiq 'require-local-checks|checks-local|check before a push|refused the push|hook (error|declined|blocked)|PreToolUse|pre-push'; then echo check
  elif printf '%s\n' "$1" | grep -Eiq '^remote:|\[remote rejected\]|protected branch|non-fast-forward|\(fetch first\)|permission denied|403|rate limit'; then echo github
  else echo unknown; fi
}

# fix_refusal_words KIND: the push refusal in plain words, for the note.
fix_refusal_words() {
  case "$1" in
    check) echo "the project's own check before a push refused it" ;;
    github) echo "GitHub refused the push" ;;
    *) echo "the push was refused" ;;
  esac
}

# fix_side_note PR KIND WAITS: the one comment a fix agent leaves when its push is refused. WAITS is the number of the issue or
# pull request the push waits on. The first line is the marker fix-side.sh reads.
fix_side_note() {
  printf 'Fix waits: #%s | side: %s\n' "$3" "$(fix_side_branch "$1")"
  printf 'My fix for this change is finished and pushed to the side branch %s, because %s. It waits on #%s. When that lands, the drive merges the side branch into this change'"'"'s branch with no agent; if that fails, a fix agent is asked again, starting from the side branch.\n' "$(fix_side_branch "$1")" "$(fix_refusal_words "$2")" "$3"
}

# fix_side_waits COMMENTS: the number the newest "Fix waits:" line names, from COMMENTS (comment bodies, newest last), or nothing.
fix_side_waits() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^Fix waits: *#\([0-9][0-9]*\).*/\1/p' | tail -n 1
}

# fix_side_failed_note SIDE: the one comment left when the side branch could not be merged; fix_side_failed COMMENTS says
# whether it is there (yes or no), so the merge is tried once and the fix agent takes over from the side branch.
fix_side_failed_note() { printf 'Fix side failed: the fix on %s could not be merged into this change'"'"'s branch on its own, so a fix agent is asked, starting from that side branch.\n' "$1"; }
fix_side_failed() { if printf '%s\n' "$1" | grep -q '^Fix side failed:'; then echo yes; else echo no; fi; }

# fix_side_action PR_STATE WAITS_STATE: what to do for a side branch. PR_STATE is open, closed or merged (the change's);
# WAITS_STATE open, closed, merged or none (what its note names; none when it names nothing or cannot be read).
#   remove: the change landed or closed, so the side branch goes; merge: what it waits on landed; wait: still waiting.
fix_side_action() {
  case "$1" in merged|closed) echo remove; return 0 ;; esac
  case "$2" in closed|merged) echo merge ;; none) echo merge ;; *) echo wait ;; esac
}
