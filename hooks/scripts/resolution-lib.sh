#!/bin/sh
# Pure helpers for the hook resolution feed. Nothing here reads a file or
# touches the network.
#
# After a hook refuses something, what the agent does next says whether
# the rule worked: it followed the message, retried the same thing, asked
# the person, moved on, or reached the same effect another way. These
# functions read one later action and say which.

# resolution_of HOOK TOOL TEXT
# HOOK is the refusing hook's name (block-delete), TOOL the name of a later
# tool call (Bash, Edit, AskUserQuestion), TEXT its command or file path.
# Print followed, workaround or asked when that action settles the
# refusal; nothing when it says nothing about it. A workaround is a best
# guess from patterns, shown to a person as "possible", never blocked.
resolution_of() {
  case "$2" in AskUserQuestion) echo asked; return 0 ;; esac
  ro_t=$(printf '%s' "$3" | tr '\r\n' '  ')
  ro_hit() { printf '%s' "$ro_t" | grep -Eq -- "$1"; }
  case "$1" in
    block-delete)
      if ro_hit 'os\.(remove|unlink|rmdir)|shutil\.rmtree|unlinkSync|rmSync|fs\.(rm|unlink)|Remove-Item|(^|[ ;&|])(del|erase|rmdir|shred) |find .* -delete|truncate -s 0'; then echo workaround
      elif ro_hit '(^|[ ;&|])(git mv|mv) '; then echo followed; fi ;;
    block-force-push)
      if ro_hit 'git push[^|;&]* \+[A-Za-z0-9_/.-]|update-ref|force=true|git push[^|;&]* :[A-Za-z]'; then echo workaround
      elif ro_hit 'git (push|pull|merge|revert)'; then echo followed; fi ;;
    require-batch-merge)
      if ro_hit 'pulls/[0-9]+/merge|git push[^|;&]* [^ ]*:(main|master)( |$)|git push[^|;&]* (main|master)( |$)'; then echo workaround
      elif ro_hit 'merge-queue\.sh'; then echo followed; fi ;;
    block-generated-page)
      if ro_hit '>>? *[^ ]*STATUS\.md|sed -i[^|;&]*STATUS\.md|tee [^|;&]*STATUS\.md'; then echo workaround
      elif ro_hit 'status/build\.sh'; then echo followed; fi ;;
    block-full-test-sweep)
      if ro_hit '\.(test|spec)\.[cm]?[jt]sx?|test_[A-Za-z0-9_]+\.py|_test\.(go|py)'; then echo followed; fi ;;
    require-state-label)
      if ro_hit 'gh issue create[^|;&]*state:'; then echo followed
      elif ro_hit 'gh api[^|;&]*issues' && ro_hit '(-X|--method) POST' && ! ro_hit 'state:'; then echo workaround; fi ;;
    block-loose-ends)
      if ro_hit 'worktrees\.sh|gh pr close[^|;&]*(--comment|-c )|\.scratch/'; then echo followed; fi ;;
    require-agent-model)
      case "$2" in Agent|Task|Workflow) echo followed ;; esac ;;
    require-clean-worktree)
      if ro_hit 'git (add|commit|stash)|worktrees\.sh'; then echo followed; fi ;;
  esac
  return 0
}

# resolution_feed REFUSALS RESOLUTIONS [LIMIT]
# REFUSALS is the hook log, "time<TAB>hook<TAB>session<TAB>id" a line (a
# line from before ids is keyed by its time); RESOLUTIONS the resolution
# log, "time<TAB>id<TAB>hook<TAB>session<TAB>outcome". Print the newest
# LIMIT (default 20) refusals, newest first, as "time<TAB>hook<TAB>outcome",
# the outcome "open" while nothing has settled it.
resolution_feed() {
  { printf '%s\n' "$2" | sed '/^$/d; s/^/R\t/'; printf '%s\n' "$1" | sed '/^$/d; s/^/H\t/'; } | tr -d '\r' | awk -F'\t' -v lim="${3:-20}" '
    $1 == "R" { out[$3] = $6; next }
    $1 == "H" { n++; t[n] = $2; h[n] = $3; id[n] = ($5 != "" ? $5 : $2) }
    END { for (i = n; i >= 1 && i > n - lim; i--) printf "%s\t%s\t%s\n", t[i], h[i], (id[i] in out ? out[id[i]] : "open") }'
}
