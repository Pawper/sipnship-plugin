#!/bin/sh
# For the nightly audit: the installed copy of the plugin, the one the drive's
# timed task runs, is named when it is more than an hour behind the newest
# published version. Each tick updates it by script first thing, so a copy
# that stays behind means the update is failing or no tick is running.
#   "The installed plugin copy is on 0.43.50, 4 releases behind 0.43.54, which was published 3 hours ago; ..."
# Prints nothing when the copy is current, was behind for less than an hour,
# or cannot be read (no installed copy listed here, GitHub not asked). REST
# only. SIPNSHIP_PLUGIN_LIST names another installed plugins file;
# SIPNSHIP_PUBLISHED and SIPNSHIP_PUBLISHED_AT (epoch seconds) stand in for
# GitHub; AUDIT_NOW (epoch seconds) stands in for the clock.
name=${SIPNSHIP_PLUGIN_NAME:-sipnship}
list=${SIPNSHIP_PLUGIN_LIST:-$HOME/.claude/plugins/installed_plugins.json}
[ -f "$list" ] || exit 0
have=$(awk -v key="\"$name@$name\"" '
  index($0, key) { inb = 1; next }
  inb && /\]/ { inb = 0 }
  inb && /"scope"/ { s = $0; sub(/.*"scope"[^"]*"/, "", s); sub(/".*/, "", s) }
  inb && /"version"/ { v = $0; sub(/.*"version"[^"]*"/, "", v); sub(/".*/, "", v); if (s == "user") u = v }
  END { print u }' "$list" | tr -d '\r')
[ -n "$have" ] || exit 0
pub=${SIPNSHIP_PUBLISHED:-}
at=${SIPNSHIP_PUBLISHED_AT:-}
if [ -z "$pub" ]; then
  tags=$(gh api "repos/Pawper/sipnship-plugin/tags?per_page=30" --jq '.[] | [.name, .commit.sha] | @tsv' 2>/dev/null | tr -d '\r') || exit 0
  best=$(printf '%s\n' "$tags" | sed 's/^plugin-//; s/^v//' | awk -F'[.\t]' 'NF >= 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
  pub=$(printf '%s' "$best" | cut -f1)
  sha=$(printf '%s' "$best" | cut -f2)
  [ -n "$pub" ] && [ -n "$sha" ] || exit 0
  when=$(gh api "repos/Pawper/sipnship-plugin/commits/$sha" --jq .commit.committer.date 2>/dev/null | tr -d '\r')
  [ -n "$when" ] && at=$(date -u -d "$when" +%s 2>/dev/null)
fi
[ -n "$pub" ] && [ -n "$at" ] || exit 0
now=${AUDIT_NOW:-$(date -u +%s)}
awk -v a="$have" -v b="$pub" -v at="$at" -v now="$now" 'BEGIN {
  split(a, x, "."); split(b, y, ".")
  behind = 0
  for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) { behind = 1; break } if (x[i] + 0 > y[i] + 0) break }
  if (!behind) exit
  secs = now - at
  if (secs <= 3600) exit
  n = (x[1] == y[1] && x[2] == y[2]) ? y[3] - x[3] : 0
  how = (n == 1) ? "1 release behind" : (n > 1 ? n " releases behind" : "behind")
  h = int(secs / 3600)
  ago = (h >= 48) ? int(h / 24) " days ago" : (h == 1 ? "1 hour ago" : h " hours ago")
  printf "The installed plugin copy is on %s, %s %s, which was published %s; the drive updates it first thing in every round, so the update is failing or no round is running. Run sh plugin/scripts/release/update-installed.sh.\n", a, how, b, ago
}'
