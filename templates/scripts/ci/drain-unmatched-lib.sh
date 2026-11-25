#!/bin/sh
# Whether a queued Queue drain job's own runs-on label matches no registered runner (#2817): a QUEUE_RUNS_ON
# variable written as a list can name a machine nobody has, whether the workflow reads it as a list or as one
# plain label. Split out of run-lib.sh to keep it under its line limit.

# drain_unmatched_label JOB_LABELS RUNNER_LABELS
# JOB_LABELS is a queued drain job's own runs-on labels, comma separated (its
# resolved labels, list or plain, read the same way whichever QUEUE_RUNS_ON
# was written as). RUNNER_LABELS is every registered runner's labels pooled,
# comma separated. Prints the one label beyond the defaults
# (self-hosted/windows/linux/macos/x64/x86/arm/arm64) the job asks for when no
# runner has it; nothing when the job asks for only defaults or a runner has
# it.
drain_unmatched_label() {
  dul_needed=$(printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | awk '
    BEGIN { split("self-hosted windows linux macos x64 x86 arm arm64", d, " "); for (i in d) def[tolower(d[i])] = 1 }
    NF && !(tolower($0) in def) { print; exit }')
  [ -n "$dul_needed" ] || return 0
  printf '%s\n' "$2" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -qix "$dul_needed" && return 0
  printf '%s\n' "$dul_needed"
}

# drain_unmatched_line LABEL
# The one plain sentence for the audit and the dashboard alike; nothing for
# an empty LABEL.
drain_unmatched_line() {
  [ -n "$1" ] || return 0
  printf 'This drain asks for a machine named %s; none of your machines has that name.\n' "$1"
}
