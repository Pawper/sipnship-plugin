#!/bin/sh
# Fail when a workflow step has no name. GitHub names such a step "Run " plus
# its script, and the Queue's runner rows would show that script as text; a
# plain name is what a builder reads. A step that only uses an action is shown by
# the action's name, never a script, so it is left alone. Reads every .github/workflows/*.yml and
# the plugin's workflow templates when they exist.
# Usage: sh scripts/ci/step-names-check.sh [FILE...]
rules_lib="$(dirname "$0")/rules-lib.sh"
if [ -f "$rules_lib" ]; then . "$rules_lib"; if rule_skip step-names; then exit 0; fi; fi
if [ $# -gt 0 ]; then files=$*
else files=$(ls .github/workflows/*.yml plugin/templates/.github/workflows/*.yml 2>/dev/null); fi
bad=""
for f in $files; do
  [ -f "$f" ] || continue
  out=$(tr -d '\r' < "$f" | awk -v f="$f" '
    function flush() { if (item != "" && !named && hasrun) printf "%s:%d: a step that runs a script and has no name\n", f, start; item = "" }
    {
      line = $0; stripped = line; sub(/^ */, "", stripped); ind = length(line) - length(stripped)
      if (stripped ~ /^#/ || stripped == "") next
      if (instep && ind <= stepsind && stripped !~ /^- /) { flush(); instep = 0 }
      if (stripped ~ /^steps:[ \t]*$/) { instep = 1; stepsind = ind; itemind = -1; next }
      if (!instep) next
      if (stripped ~ /^- / && (itemind < 0 || ind == itemind)) {
        if (ind < stepsind) { flush(); instep = 0; next }
        flush(); itemind = ind; item = 1; start = NR; named = 0; hasrun = 0
        k = substr(stripped, 3); first = k; sub(/:.*/, "", first)
        if (k ~ /^name:/) named = 1; if (k ~ /^run:/) hasrun = 1
        next
      }
      if (item != "" && ind > itemind && stripped ~ /^name:/ && ind == itemind + 2) named = 1
      if (item != "" && ind == itemind + 2 && stripped ~ /^run:/) hasrun = 1
    }
    END { flush() }')
  [ -z "$out" ] || bad="$bad$out
"
done
if [ -n "$(printf '%s' "$bad" | tr -d '\n')" ]; then
  echo "Every workflow step needs a plain name: GitHub shows an unnamed one as its script. Add a name: line to each step below." >&2
  printf '%s' "$bad" >&2
  exit 1
fi
echo "Every workflow step has a name."
