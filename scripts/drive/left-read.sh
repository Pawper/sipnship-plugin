#!/bin/sh
# Record that the drive's reader looked at a partly landed issue, so the plan
# does not send a reader to it again (left-reader-lib.sh).
#
# Usage, from the project root: sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/left-read.sh" ISSUE read|unclear
#   read     the reader left a Left: line, or closed the issue, or wrote the ask
#   unclear  the reader could not tell; the plan then says so as a question to the builder
case "${1:-}" in ''|*[!0-9]*) echo "usage: left-read.sh ISSUE read|unclear" >&2; exit 1 ;; esac
case "${2:-}" in read|unclear) ;; *) echo "usage: left-read.sh ISSUE read|unclear" >&2; exit 1 ;; esac
mkdir -p .scratch/drive
printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" >> .scratch/drive/left-read.tsv
echo "issue $1 is read ($2); the plan sends no reader to it again"
