#!/bin/sh
# The suite's blocks, its parts and stopping at the first red.
# Sourced by tests/run.sh; pure apart from printing.
#
# A block starts with a line  section 'NAME'  at the start of a line. The
# lines before the first block are the prelude, kept in every part; the
# lines from "# --- end of blocks" on are the summary, kept in every part.

# The blocks of the queue part, one name per line, exactly as in run.sh.
parts_queue_blocks='batch_merge_reason
batch helpers
the queue runs a test file with its own runner
reading a run
the queue on the service road (spec 006)
merging only through the queue
drain
check-runs and mergeable_state through REST
batches and the drain, sharing pull requests
a batch anchored on the earliest pull request
when a green pull request needs a second run
labels over REST, and waiting on a machine
serial merges, enforced by the queue
the API budget and one queue at a time
waits for a runner and the machine line'


# part_names: the parts CI runs side by side.
part_names() { printf 'shell\nconsole\nqueue\n'; }

# part_of NAME: the part a block belongs to.
part_of() {
  case "$1" in 'owner console (node)') echo console; return ;; esac
  if printf '%s\n' "$parts_queue_blocks" | grep -qxF -- "$1"; then echo queue; else echo shell; fi
}

# part_script PART < run.sh: the script with only that part's blocks.
part_script() {
  awk -v part="$1" -v queue="$parts_queue_blocks" '
    BEGIN { n = split(queue, q, "\n"); for (i = 1; i <= n; i++) isq[q[i]] = 1; keep = 1 }
    /^# --- end of blocks/ { keep = 1 }
    /^section '\''/ {
      name = $0; sub(/^section '\''/, "", name); sub(/'\''$/, "", name)
      gsub(/'\''"'\''"'\''/, "'\''", name)
      p = (name == "owner console (node)") ? "console" : ((name in isq) ? "queue" : "shell")
      keep = (p == part)
    }
    keep'
}

# block_failed TEXT: record a failure's lines against the current block.
block_failed() {
  block_fails="${block_fails:+$block_fails
}$1"
}

# stop_if_red: with --fail-fast, end at the first block that failed,
# naming it and its failing lines.
stop_if_red() {
  [ "$fail_fast" = yes ] && [ -n "$block_fails" ] || return 0
  printf '\nStopped at the first failing block: %s\n%s\n' "$block" "$block_fails"
  printf '\n%s passed, %s failed (stopped early)\n' "$pass" "$fail"
  exit 1
}

# section NAME: start a block.
section() {
  stop_if_red
  block=$1
  block_fails=
  printf '\n# %s\n' "$1"
}
