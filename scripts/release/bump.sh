#!/bin/sh
# Bump the plugin to a new version in one step.
#
#   sh plugin/scripts/release/bump.sh X.Y.Z [--all] [--no-known]
#
# Sets VERSION in .claude-plugin/plugin.json, package.json and every
# occurrence on the version badge line of README.md (the alt text and the
# badge URL), then refreshes templates/KNOWN.txt with
# scripts/sync/known-hashes.sh: the committed list plus the versions since
# it was last written (seconds), or with --all the full rebuild from
# history (minutes). It finds the
# repository root from its own location, so it works from any directory.
# Running it twice with the same version changes nothing the second time.
#
# --no-known  skip regenerating KNOWN.txt (the tests use this).
set -e

version=
known=yes
all=no
for a in "$@"; do
  case "$a" in
    --no-known) known=no ;;
    --all) all=yes ;;
    *) version=$a ;;
  esac
done
bad() { echo "not a version: $version (expected X.Y.Z)" >&2; exit 2; }
case "$version" in
  "" | *[!0-9.]* | .* | *..* | *.) bad ;;
esac
[ "$(printf '%s' "$version" | tr -cd . | wc -c | tr -d ' ')" = 2 ] || bad

plugin=$(cd "$(dirname "$0")/../.." && pwd)
repo=$(cd "$plugin/.." && pwd)

# swap FILE SED-EXPRESSION: rewrite only when the result differs.
swap() {
  sed -e "$2" "$1" > "$1.new"
  if cmp -s "$1" "$1.new"; then rm -f "$1.new"; else cat "$1.new" > "$1"; rm -f "$1.new"; fi
}

swap "$plugin/.claude-plugin/plugin.json" '/^  "version":/s/"version": *"[^"]*"/"version": "'"$version"'"/'
swap "$plugin/package.json" '/^  "version":/s/"version": *"[^"]*"/"version": "'"$version"'"/'
swap "$plugin/README.md" '/img\.shields\.io\/badge\/version-/{s/alt="Version [^"]*"/alt="Version '"$version"'"/;s/badge\/version-[0-9][0-9.]*-/badge\/version-'"$version"'-/;}'

if [ "$known" = yes ]; then
  # The committed list plus what came since the commit that last wrote it:
  # seconds. The full rebuild from all of history (minutes) only with
  # --all, or when no list is committed yet.
  from=$(cd "$repo" && git log -1 --format=%H -- plugin/templates/KNOWN.txt 2>/dev/null || true)
  if [ "$all" = yes ] || [ -z "$from" ]; then
    echo "Regenerating templates/KNOWN.txt from all of history; this takes a few minutes."
    range=--all
  else
    echo "Refreshing templates/KNOWN.txt with the template versions since it was last written."
    range="$from..HEAD"
  fi
  (cd "$repo" && sh plugin/scripts/sync/known-hashes.sh "$range" > plugin/templates/KNOWN.txt.new && cat plugin/templates/KNOWN.txt.new > plugin/templates/KNOWN.txt && rm -f plugin/templates/KNOWN.txt.new)
fi

echo "Version is $version. Two commands are left:"
echo "  1. the suite:   (cd plugin && sh tests/run.sh)"
echo "  2. the release: split and push the plugin as usual"
