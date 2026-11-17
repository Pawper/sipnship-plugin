#!/bin/sh
# Keeps the folders agents work in out of Windows Search (specs/015-setup-flow).
# Windows leaves out, by itself, a folder that holds a git repository, but a
# worktree has a `.git` file instead, so the indexer reads everything an agent
# installs there. The plugin adds one exclusion rule for the folder that holds
# the worktrees and one for the queue's batch folder, through the indexer's own
# interface for a user's rules, which needs no administrator rights. On a
# machine that is not Windows every function here does nothing.

# search_index_applies UNAME
# Print "yes" when UNAME (the output of `uname -s`) is a Windows shell.
search_index_applies() {
  case "$1" in
    MINGW*|MSYS*|CYGWIN*) echo yes ;;
    *) echo no ;;
  esac
}

# search_index_ps ACTION DIR
# Run the indexer script for DIR and print its one word: "out", "in" or
# "unknown". Prints "unknown" anywhere but Windows, and when the script cannot
# run. Bounded, so a stalled indexer never holds a hook.
search_index_ps() {
  [ "$(search_index_applies "$(uname -s 2>/dev/null)")" = yes ] || { echo unknown; return 0; }
  _si_script=${SEARCH_INDEX_SCRIPT:-${SEARCH_INDEX_HOME:-}/search-index.ps1}
  [ -f "$_si_script" ] && [ -d "$2" ] || { echo unknown; return 0; }
  _si_w=$(cygpath -w "$_si_script" 2>/dev/null || printf '%s' "$_si_script")
  _si_f=$(cygpath -w "$2" 2>/dev/null || printf '%s' "$2")
  _si_out=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$_si_w" "$1" "$_si_f" 2>/dev/null | tr -d '\r' | tail -n 1)
  case "$_si_out" in out|in) echo "$_si_out" ;; *) echo unknown ;; esac
}

# search_index_state DIR: "out", "in" or "unknown", changing nothing.
search_index_state() { search_index_ps check "$1"; }

# search_index_exclude DIR
# Leave DIR out of the index (a rule is added only when it is still in). Prints
# the state afterwards. Never removes a rule.
search_index_exclude() { search_index_ps exclude "$1"; }

# search_index_note STATES
# STATES is one folder per line as "NAME<TAB>STATE" (STATE is out, in or
# unknown). Print one plain sentence naming the folders still in the index,
# nothing when none is. A folder whose state is unknown is not named: the
# brief says what it knows.
search_index_note() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 2 && $2 == "in" { n++; names = names (n > 1 ? ", " : "") $1 }
    END {
      if (n == 1) print "Windows Search is still reading " names ", where your agents work, which costs processor all day. Setup leaves it out of the index with no step from you."
      else if (n > 1) print "Windows Search is still reading " n " folders where your agents work (" names "), which costs processor all day. Setup leaves them out of the index with no step from you."
    }'
}
