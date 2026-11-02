# Sourced by session-brief-slow.sh, in the background: the files over their
# size limit, the files several open pull requests edit, and the CI jobs over
# their time limit (scripts/ci/hotspots.txt). Local git and files only, but a
# git diff per open pull request, so too slow for the start hook itself; the
# brief prints the cached line with its age.
if has leftover && [ -f scripts/ci/hotspots.txt ] && [ -f scripts/ci/hotspots-lib.sh ] && [ "$have_git" = yes ]; then
  . scripts/ci/hotspots-lib.sh
  hs_spec=$(cat scripts/ci/hotspots.txt)
  hs_counts=$(git ls-files 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|cjs|css|scss|sh|py|go|rs|swift|kt)$' | tr '\n' '\0' | xargs -0 wc -l 2>/dev/null | awk '$2 != "total" && $1 >= 200 { print $1 "\t" $2 }' | sort -rn)
  hs_scan=$(hotspot_scan "$hs_spec" "$hs_counts")
  hs_over=$(printf '%s\n' "$hs_scan" | awk -F'\t' '$1 == "over" { print $2 }')
  hs_near=$(printf '%s\n' "$hs_scan" | awk -F'\t' '$1 == "near" { print $2 }')
  hs_busy=$(printf '%s\n' "$facts" | awk -F'\t' '$1 == "pr" && $6 != "" { print $6 }' | head -n 15 | while read -r hs_h; do
    git diff --name-only "origin/main...origin/$hs_h" 2>/dev/null
  done | sort | uniq -c | awk '$1 >= 2 { print $2 "\t" $1 }')
  hs_jobs=""
  if [ -n "$ml_file" ] && [ -f "$(dirname "$ml_file")/timings.tsv" ]; then
    hs_jobs=$(hotspot_jobs_over "$(hotspot_job_averages "$(cat "$(dirname "$ml_file")/timings.tsv")")" "$hs_spec")
  fi
  hs_line=$(hotspot_brief_line "$hs_over" "$hs_near" "$hs_busy" "$hs_jobs")
  [ -z "$hs_line" ] || add "$hs_line"
fi
