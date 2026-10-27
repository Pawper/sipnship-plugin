#!/bin/sh
# The screens job: for each screen a pull request touches that has a route
# in scripts/ci/mocks.txt, render its mock and its built route side by side
# (scripts/design/screens-diff.mjs) and write the table to OUT/table.md.
# A share above the threshold is flagged, never failed; the job fails only
# when a screen cannot be rendered. It records nothing in design/screens.txt:
# a person does, after looking.
# Usage: sh scripts/design/screens-run.sh BASE HEAD OUT
#    or: BUILT_BASE=URL sh scripts/design/screens-run.sh BASE HEAD OUT
#        (a base URL already serving the app; serve.sh is not started)
here=$(dirname "$0")
. "$here/../ci/mock-lib.sh"
base=${1:?usage: screens-run.sh BASE HEAD OUT}; head=${2:?}; out=${3:?}
cfg=scripts/ci/mocks.txt
[ -f "$cfg" ] || { echo "No $cfg; no screens to render."; exit 0; }
text=$(cat "$cfg")
routes=$(mock_routes "$text")
[ -n "$routes" ] || { echo "No line in $cfg has an @/route; no screens to render."; exit 0; }
if git rev-parse -q --verify "$head^2" >/dev/null 2>&1; then base=$(git rev-parse "$head^1")
else mb=$(git merge-base "$base" "$head" 2>/dev/null) && base=$mb; fi
changed=$(git diff --name-only "$base" "$head") || { echo "Could not read the diff between $base and $head." >&2; exit 2; }
touched=$(mock_touched "$changed" "$text")
todo=$(printf '%s\n' "$routes" | while IFS='	' read -r n r m; do printf '%s\n' "$touched" | grep -qx "$n" && printf '%s\t%s\t%s\n' "$n" "$r" "$m"; done)
[ -n "$todo" ] || { echo "No touched screen has a route; nothing to render."; exit 0; }
threshold=$(mock_header threshold 0.05 "$text")
mkdir -p "$out"
started=""
if [ -z "${BUILT_BASE:-}" ]; then
  [ -f scripts/design/serve.sh ] || { echo "No scripts/design/serve.sh; the built screens have nowhere to come from."; exit 0; }
  if grep -qx '# screens: stub' scripts/design/serve.sh; then echo "scripts/design/serve.sh is still the stub; fill it in to see each screen beside its mock."; exit 0; fi
  FIXTURES=$(mock_header fixtures "" "$text"); export FIXTURES
  BUILT_BASE=$(sh scripts/design/serve.sh start | head -n 1) || BUILT_BASE=""
  started=yes
  trap 'sh scripts/design/serve.sh stop >/dev/null 2>&1 || true' EXIT
  [ -n "$BUILT_BASE" ] || { echo "scripts/design/serve.sh start printed no base URL; could not render the built screens." >&2; exit 2; }
fi
fail=0
{
  echo "| Screen | Differing pixels | Flagged |"
  echo "|---|---|---|"
} > "$out/table.md"
printf '%s\n' "$todo" | while IFS='	' read -r n r m; do
  line=$(node "$here/screens-diff.mjs" "$n" "$m" "${BUILT_BASE%/}$r" "$out" --threshold "$threshold") || { echo "$n: could not render" >&2; echo "| $n | not rendered | |" >> "$out/table.md"; echo x >> "$out/.failed"; continue; }
  echo "$line"
  d=$(printf '%s\n' "$line" | sed -n 's/.* diff=\([0-9.]*\) .*/\1/p'); f=$(printf '%s\n' "$line" | sed -n 's/.* flagged=\([a-z]*\) .*/\1/p')
  pct=$(awk -v d="$d" 'BEGIN { printf "%.1f%%", d * 100 }')
  if [ "$f" = yes ]; then echo "| $n | $pct | above $threshold, look at it |" >> "$out/table.md"; else echo "| $n | $pct | no |" >> "$out/table.md"; fi
done
[ ! -f "$out/.failed" ] || fail=2
[ -n "$started" ] && { sh scripts/design/serve.sh stop >/dev/null 2>&1 || true; trap - EXIT; }
exit "$fail"
