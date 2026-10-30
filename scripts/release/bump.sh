#!/bin/sh
# Bump the plugin to a new version in one step.
#
#   sh plugin/scripts/release/bump.sh X.Y.Z [--no-known]
#
# Sets VERSION in .claude-plugin/plugin.json, package.json and every
# occurrence on the version badge line of README.md (the alt text and the
# badge URL), then regenerates templates/KNOWN.txt with
# scripts/sync/known-hashes.sh (about three minutes). It finds the
# repository root from its own location, so it works from any directory.
# Running it twice with the same version changes nothing the second time.
#
# --no-known  skip regenerating KNOWN.txt (the tests use this).
set -e

version=
known=yes
for a in "$@"; do
  case "$a" in
    --no-known) known=no ;;
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
  echo "Regenerating templates/KNOWN.txt from history; this takes about three minutes."
  (cd "$repo" && sh plugin/scripts/sync/known-hashes.sh --all > plugin/templates/KNOWN.txt.new && cat plugin/templates/KNOWN.txt.new > plugin/templates/KNOWN.txt && rm -f plugin/templates/KNOWN.txt.new)
fi

echo "Version is $version. Two commands are left:"
echo "  1. the suite:   (cd plugin && sh tests/run.sh)"
echo "  2. the release: split and push the plugin as usual"
