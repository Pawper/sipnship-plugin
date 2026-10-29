#!/bin/sh
# Write templates/KNOWN.txt: one "PATH HASH" line for every released
# version of every plugin-owned file, from this repository's history (the
# plugin's own history came along when it moved here, under templates/;
# since then it is under plugin/templates/). The template sync calls a
# project's file the plugin's only when its content matches one of these,
# so a project's own file of the same name is never replaced.
#
# Run from the repository root before each release:
#   sh plugin/scripts/sync/known-hashes.sh > plugin/templates/KNOWN.txt
# The plugin's tests fail when a current template is missing from it.
set -e
here=$(dirname "$0")
. "$here/sync-lib.sh"
owned=$(cat plugin/templates/OWNED.txt)
# Files the templates no longer carry, whose released versions the sync
# must still know so it removes an unedited copy: the hosted Runner watch,
# which failed at every schedule in a private repository whose hosted
# minutes are used up.
retired=".github/workflows/runner-watch.yml"
{
  for p in $(owned_paths "$owned") $retired; do
    for old in "templates/$p" "plugin/templates/$p"; do
      for rev in $(git log --all --full-history --format=%H -- "$old"); do
        t=$(git show "$rev:$old" 2>/dev/null) || continue
        printf '%s %s\n' "$p" "$(norm_hash "$t")"
      done
    done
    if [ -f "plugin/templates/$p" ]; then printf '%s %s\n' "$p" "$(norm_hash "$(cat "plugin/templates/$p")")"; fi
  done
} | sort -u
