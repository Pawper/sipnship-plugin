#!/bin/sh
# The suite's blocks, its parts and stopping at the first red.
# Sourced by tests/run.sh; pure apart from printing.
#
# A block starts with a line  section 'NAME'  at the start of a line. The
# lines before the first block are the prelude, kept in every part; the
# lines from "# --- end of blocks" on are the summary, kept in every part.
#
# Which part a block belongs to lives in one data file, tests/parts.txt: a
# line is  PART NAME  (the part, a space, the block's name exactly as its
# section line gives it, quotes unescaped). A block the file does not name
# runs in no part, and a test of the suite fails it.

parts_file() { printf '%s\n' "${PARTS_FILE:-$root/tests/parts.txt}"; }

# parts_data: the assignment file, comments and blank lines dropped.
parts_data() { tr -d '\r' < "$(parts_file)" | grep -v '^[ 	]*\(#\|$\)'; }

# part_names: the parts CI runs side by side, in the file's order.
part_names() { parts_data | awk '{ if (!($1 in s)) { s[$1] = 1; print $1 } }'; }

# suite_blocks < run.sh: the name of every block, one per line.
suite_blocks() {
  awk '/^section '\''/ {
    name = $0; sub(/^section '\''/, "", name); sub(/'\''$/, "", name)
    gsub(/'\''"'\''"'\''/, "'\''", name); print name }'
}

# part_of NAME: the part a block belongs to; nothing when it is unassigned.
part_of() {
  parts_data | awk -v b="$1" '{ n = $0; sub(/^[^ ]+ /, "", n); if (n == b) { print $1; exit } }'
}

# part_script PART < run.sh: the script with only that part's blocks.
part_script() {
  PARTS_DATA=$(parts_data) awk -v part="$1" '
    BEGIN {
      n = split(ENVIRON["PARTS_DATA"], q, "\n")
      for (i = 1; i <= n; i++) {
        name = q[i]; sub(/^[^ ]+ /, "", name)
        of[name] = substr(q[i], 1, length(q[i]) - length(name) - 1)
      }
      keep = 1
    }
    /^# --- end of blocks/ { keep = 1 }
    /^section '\''/ {
      name = $0; sub(/^section '\''/, "", name); sub(/'\''$/, "", name)
      gsub(/'\''"'\''"'\''/, "'\''", name)
      keep = ((name in of) && of[name] == part)
    }
    keep'
}

# parts_touching FILE... < run.sh: the parts with a block that names any of
# the files (a path under plugin/ is looked for without that prefix, as
# the suite writes it), one per line, in the parts file's order.
parts_touching() {
  pt_script=$(cat)
  for pt_part in $(part_names); do
    for pt_file in "$@"; do
      pt_rel=${pt_file#plugin/}; pt_rel=${pt_rel#./}
      # The console's own files are run whole by the one console block.
      case "$pt_rel" in console/*) [ "$pt_part" = console ] && { printf '%s\n' console; break; } ;; esac
      if printf '%s\n' "$pt_script" | part_script "$pt_part" | grep -qF -- "$pt_rel"; then
        printf '%s\n' "$pt_part"; break
      fi
    done
  done
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

# block_limit NAME LIMITS: the seconds block NAME may take. LIMITS is the
# text of tests/block-limits.txt, "SECONDS NAME" a line; a block it does
# not name gets 60.
block_limit() {
  printf '%s\n' "$2" | tr -d '\r' | awk -v b="$1" '
    /^[ \t]*(#|$)/ { next }
    { n = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == b) { print n; found = 1; exit } }
    END { if (!found) print 60 }'
}

# block_end: print the block that just ended and its seconds, and warn
# when it took longer than its limit. It never fails the run: a check
# passes or fails on whether the work is right, and time is a metric.
block_end() {
  [ -n "$block" ] && [ -n "$block_start" ] || return 0
  be_s=$(( $(date +%s) - block_start ))
  be_l=$(block_limit "$block" "$(cat "$root/tests/block-limits.txt" 2>/dev/null)")
  printf 'time  %s: %ss (limit %ss)\n' "$block" "$be_s" "$be_l"
  if [ "$be_s" -gt "$be_l" ]; then
    printf 'WARN  the block "%s" took %ss, over its limit of %ss (it passes; time is watched on Cost, never gated)\n' "$block" "$be_s" "$be_l"
    [ -n "$GITHUB_ACTIONS" ] && printf '::warning title=A slow test block::"%s" took %ss, over its limit of %ss\n' "$block" "$be_s" "$be_l"
  fi
  block_count=$(( ${block_count:-0} + 1 ))
  if [ "$be_s" -gt 120 ]; then
    printf 'slow  %s: %ss (over two minutes)\n' "$block" "$be_s"
    slow_blocks="${slow_blocks:+$slow_blocks, }$block ($be_s s)"
  fi
  block_start=
}

# section NAME: start a block.
section() {
  block_end
  stop_if_red
  block=$1
  block_fails=
  block_start=$(date +%s)
  printf '\n# %s\n' "$1"
}
