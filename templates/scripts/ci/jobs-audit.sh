#!/bin/sh
# For the nightly audit: every job of the project's workflows that has no line
# in .github/jobs.txt, one line each, "name (workflow file)". A job with no
# line is shown on the dashboard as a check whose workflow does not say what
# for yet. A job is named by its "name:" when it has one, otherwise by its key;
# a line "tests" also covers its parts, "tests (shell-1)". Local files only;
# prints nothing when all is well or there is nothing to read.
dir=${1:-.github}
[ -f "$dir/jobs.txt" ] || exit 0
for wf in "$dir"/workflows/*.yml; do
  [ -f "$wf" ] || continue
  awk '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[A-Za-z]/ { injobs = 0 }
    injobs && /^  [A-Za-z0-9_-]+:[ \t]*(#.*)?$/ { if (key != "") print (nm != "" ? nm : key); key = $1; sub(/:$/, "", key); nm = ""; next }
    injobs && key != "" && nm == "" && /^    name:[ \t]*[^ \t$]/ {
      v = $0; sub(/^    name:[ \t]*/, "", v); gsub(/^["\047]|["\047]$/, "", v); if (v !~ /\$\{\{/) nm = v
    }
    END { if (key != "") print (nm != "" ? nm : key) }
  ' "$wf" | while IFS= read -r job; do
    base=$(printf '%s' "$job" | sed 's/ *(.*)$//')
    grep -q -F -x -e "$job | " "$dir/jobs.txt" 2>/dev/null && continue
    if awk -F' [|] ' -v a="$job" -v b="$base" '!/^#/ && ($1 == a || $1 == b) { f = 1 } END { exit !f }' "$dir/jobs.txt"; then continue; fi
    printf '%s (%s)\n' "$job" "$(basename "$wf")"
  done
done
exit 0
