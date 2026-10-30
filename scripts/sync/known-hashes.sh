#!/bin/sh
# Write templates/KNOWN.txt: one "PATH HASH" line for every released
# version of every plugin-owned file, from this repository's history (the
# plugin's own history came along when it moved here, under templates/;
# since then it is under plugin/templates/). The template sync calls a
# project's file the plugin's only when its content matches one of these,
# so a project's own file of the same name is never replaced.
#
# Two forms, both run from the repository root:
#   sh plugin/scripts/sync/known-hashes.sh FROM..HEAD
#     The committed list plus the versions the range added: each owned
#     file at each commit in the range that changed it (a merge counts,
#     against either parent), and the working-tree version. Seconds, not
#     minutes; the queue runs it after a merge that changes a template.
#     Over a range whose start the committed list already covered, the
#     output is byte-identical to the full rebuild.
#   sh plugin/scripts/sync/known-hashes.sh --all > plugin/templates/KNOWN.txt
#     The full rebuild from all of history, for releases.
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
case "$1" in
  --all)
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
    ;;
  *..*)
    paths=$(owned_paths "$owned"; for r in $retired; do echo "$r"; done)
    {
      tr -d '\r' < plugin/templates/KNOWN.txt 2>/dev/null || true
      for rev in $(git rev-list --full-history "$1" -- plugin/templates/); do
        for f in $(git diff-tree -m -r --root --no-commit-id --name-only "$rev" -- plugin/templates/ | sort -u); do
          p=${f#plugin/templates/}
          printf '%s\n' "$paths" | grep -qxF "$p" || continue
          t=$(git show "$rev:$f" 2>/dev/null) || continue
          printf '%s %s\n' "$p" "$(norm_hash "$t")"
        done
      done
      # The working-tree version of each owned file the range or the
      # working tree changed; every other one is in the committed list.
      for f in $( { git diff --name-only "${1%%..*}" -- plugin/templates/; git ls-files --others --exclude-standard -- plugin/templates/; } | sort -u); do
        p=${f#plugin/templates/}
        printf '%s\n' "$paths" | grep -qxF "$p" || continue
        if [ -f "$f" ]; then printf '%s %s\n' "$p" "$(norm_hash "$(cat "$f")")"; fi
      done
    } | sort -u
    ;;
  *)
    echo "usage: known-hashes.sh --all | FROM..HEAD" >&2
    exit 2
    ;;
esac
