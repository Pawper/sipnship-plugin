#!/bin/sh
# Pure helpers for the hotspots check: a source file is one unit of change,
# small enough that two agents rarely need it at once. Text in, text out.
#
# The list is scripts/ci/hotspots.txt, one rule a line (# starts a comment):
#   exempt GLOB...        not measured (tests, generated files); first match wins
#   limit LINES GLOB...   the most lines a matching file may have; first match wins,
#                         so a per-path line goes above the defaults
#   shrink PATH           already over its limit: may shrink, may not grow
#   warn-at PERCENT       warn when a file reaches this share of its limit (80)
#   job NAME MINUTES      the usual time a CI job may take; "job default 3"
#   shrink-job NAME       a job already over its limit, to be split
# A GLOB is a shell pattern over the whole path, so *.css matches in any folder.

# hotspot_rules SPEC
# The spec without comments, carriage returns or blank lines.
hotspot_rules() {
  printf '%s\n' "$1" | tr -d '\r' | sed 's/#.*//' | awk 'NF'
}

# hotspot_limit PATH SPEC
# The line limit for PATH, or nothing when it is exempt or no rule names it.
hotspot_limit() {
  hl_path=$(printf '%s' "$1" | tr '\\' '/')
  hotspot_rules "$2" | {
    set -f
    while read -r hl_kind hl_a hl_rest; do
      case "$hl_kind" in
        exempt) for hl_pat in $hl_a $hl_rest; do case "$hl_path" in $hl_pat) exit 0 ;; esac; done ;;
        limit) for hl_pat in $hl_rest; do case "$hl_path" in $hl_pat) printf '%s\n' "$hl_a"; exit 0 ;; esac; done ;;
      esac
    done
  }
}

# hotspot_listed PATH SPEC
# "yes" when PATH is on the shrink-only list.
hotspot_listed() {
  hotspot_rules "$2" | awk -v p="$(printf '%s' "$1" | tr '\\' '/')" '$1 == "shrink" && $2 == p { print "yes"; exit }'
}

# hotspot_warn_at SPEC
# The share of the limit, in percent, at which a file is flagged.
hotspot_warn_at() {
  hw=$(hotspot_rules "$1" | awk '$1 == "warn-at" && $2 ~ /^[0-9]+$/ { print $2; exit }')
  printf '%s\n' "${hw:-80}"
}

# hotspot_verdict PATH SPEC BASE_LINES NEW_LINES
# Nothing for a file with no limit or nothing to say. Otherwise one line:
# "fail<TAB>why" or "warn<TAB>why". BASE_LINES is 0 for a new file.
#   over the limit and growing (or new)  fail: split before you add
#   over the limit and not growing       passes; warns when it is not on the shrink-only list
#   on the list but under its limit now  warn: take it off the list
#   at the warn share of the limit       warn: split it before the next change
hotspot_verdict() {
  hv_limit=$(hotspot_limit "$1" "$2")
  [ -n "$hv_limit" ] || return 0
  hv_listed=$(hotspot_listed "$1" "$2")
  hv_at=$(hotspot_warn_at "$2")
  hv_base=${3:-0}; hv_new=${4:-0}
  if [ "$hv_new" -gt "$hv_limit" ]; then
    if [ "$hv_new" -gt "$hv_base" ]; then
      if [ "$hv_base" -eq 0 ]; then
        printf 'fail\t%s is new and has %s lines, over the limit of %s. Split before you add: cut it by the unit of change (a screen, a section, a queue step) into files of their own.\n' "$1" "$hv_new" "$hv_limit"
      else
        printf 'fail\t%s has %s lines, over the limit of %s, and this change adds to it (it had %s). Split before you add: move one unit of change into a file of its own first, then make the change on the smaller files.\n' "$1" "$hv_new" "$hv_limit" "$hv_base"
      fi
    elif [ "$hv_listed" != yes ]; then
      printf 'warn\t%s has %s lines, over the limit of %s, and is not on the shrink-only list. Add it to scripts/ci/hotspots.txt with its split issue.\n' "$1" "$hv_new" "$hv_limit"
    fi
    return 0
  fi
  if [ "$hv_listed" = yes ]; then
    printf 'warn\t%s is down to %s lines, under its limit of %s. Take it off the shrink-only list.\n' "$1" "$hv_new" "$hv_limit"
  elif [ $((hv_new * 100)) -ge $((hv_limit * hv_at)) ]; then
    printf 'warn\t%s has %s of its %s lines. Split it before the next change to it: the next agent that needs it moves a unit out first, then makes the change.\n' "$1" "$hv_new" "$hv_limit"
  fi
  return 0
}

# hotspot_join NUMBERS
# "348 362" as "#348 and #362"; three or more as "#348, #362 and #370".
hotspot_join() {
  printf '%s\n' "$1" | awk '{
    for (i = 1; i <= NF; i++) { s = "#" $i; if (i == 1) out = s; else if (i == NF) out = out " and " s; else out = out ", " s }
    print out }'
}

# hotspot_overlap_rows CHANGED OTHERS MIN
# CHANGED is the paths this pull request edits, one a line. OTHERS is the
# paths the other open pull requests edit, "NUMBER<TAB>PATH" a line. Print
# "PATH<TAB>NUMBERS" for each path that at least MIN other pull requests
# also edit, in CHANGED's order.
hotspot_overlap_rows() {
  hr_min=${3:-2}
  hr_other=$(mktemp "${TMPDIR:-/tmp}/hot.XXXXXX") || return 0
  printf '%s\n' "$2" | tr -d '\r' | tr '\\' '/' > "$hr_other"
  printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | awk -F'\t' -v min="$hr_min" -v other="$hr_other" '
    BEGIN { while ((getline line < other) > 0) { split(line, f, "\t"); if (f[1] != "" && f[2] != "") { k = f[2] SUBSEP f[1]; if (!(k in seen)) { seen[k] = 1; prs[f[2]] = prs[f[2]] " " f[1]; n[f[2]]++ } } } }
    NF && ($0 in n) && n[$0] >= min { s = prs[$0]; sub(/^ /, "", s); print $0 "\t" s }'
  rm -f "$hr_other"
  return 0
}

# hotspot_overlap_say PATH NUMBERS
# The row's words: "Overlaps #348 and #362 in dashboard.ts".
hotspot_overlap_say() {
  printf 'Overlaps %s in %s\n' "$(hotspot_join "$2")" "$(basename "$1")"
}

# hotspot_job_limit NAME SPEC
# The usual minutes a job may take: its own "job NAME MINUTES" line, else
# "job default MINUTES", else three.
hotspot_job_limit() {
  hj=$(hotspot_rules "$2" | awk -v n="$1" '$1 == "job" && $2 == n && $3 ~ /^[0-9]+$/ { print $3; exit }')
  [ -n "$hj" ] || hj=$(hotspot_rules "$2" | awk '$1 == "job" && $2 == "default" && $3 ~ /^[0-9]+$/ { print $3; exit }')
  printf '%s\n' "${hj:-3}"
}

# hotspot_job_averages TIMINGS
# TIMINGS is the runner watch's timings file (job, start epoch, seconds, ...,
# tab separated). Print "JOB<TAB>AVERAGE_SECONDS" for each job.
hotspot_job_averages() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' 'NF >= 3 && $1 != "" && $3 ~ /^[0-9]+$/ { s[$1] += $3; c[$1]++; if (!($1 in o)) { o[$1] = ++k; name[k] = $1 } }
    END { for (i = 1; i <= k; i++) printf "%s\t%d\n", name[i], s[name[i]] / c[name[i]] }'
}

# hotspot_jobs_over AVERAGES SPEC
# AVERAGES is "JOB<TAB>SECONDS" a line. One line a job over its limit:
# "checks takes about 7 minutes (limit 5): long, split it".
hotspot_jobs_over() {
  printf '%s\n' "$1" | tr -d '\r' | while IFS="$(printf '\t')" read -r hj_name hj_sec; do
    [ -n "$hj_name" ] || continue
    hj_lim=$(hotspot_job_limit "$hj_name" "$2")
    if [ "$hj_sec" -gt $((hj_lim * 60)) ]; then
      printf '%s takes about %s minutes (limit %s): long, split it\n' "$hj_name" $(((hj_sec + 30) / 60)) "$hj_lim"
    fi
  done
}

# hotspot_brief_line OVER NEAR BUSY JOBS
# The session brief's line. OVER and NEAR are paths (one a line) over their
# limit and at the warn share; BUSY is "PATH<TAB>COUNT" for the files the
# most open pull requests edit; JOBS is hotspot_jobs_over's output. Nothing
# when all four are empty.
hotspot_brief_line() {
  hb=""
  hb_n=$(printf '%s\n' "$1" | awk 'NF' | wc -l | tr -d ' ')
  hb_over=$(printf '%s\n' "$1" | awk 'NF' | head -n 3 | paste -sd',' - | sed 's/,/, /g')
  [ "$hb_n" -le 3 ] || hb_over="$hb_n files, the biggest $hb_over"
  hb_near=$(printf '%s\n' "$2" | awk 'NF' | head -n 5 | paste -sd',' - | sed 's/,/, /g')
  hb_busy=$(printf '%s\n' "$3" | tr -d '\r' | awk -F'\t' 'NF >= 2 && $2 + 0 >= 2 { printf "%s (%s open pull requests)\n", $1, $2 }' | head -n 3 | paste -sd';' - | sed 's/;/, /g')
  hb_jobs=$(printf '%s\n' "$4" | awk 'NF' | head -n 3 | paste -sd';' - | sed 's/;/, /g')
  [ -z "$hb_over" ] || hb="Over the size limit (may shrink, not grow): $hb_over."
  [ -z "$hb_near" ] || hb="${hb:+$hb }Near it, split before the next change: $hb_near."
  [ -z "$hb_busy" ] || hb="${hb:+$hb }Edited by several open pull requests: $hb_busy."
  [ -z "$hb_jobs" ] || hb="${hb:+$hb }CI jobs over their time limit: $hb_jobs."
  [ -z "$hb" ] || printf 'Hotspots: %s\n' "$hb"
  return 0
}

# hotspot_scan SPEC LINES
# LINES is "COUNT<TAB>PATH" a line. One line each for a measured file over
# its limit ("over<TAB>PATH") or at the warn share of it ("near<TAB>PATH").
# One shell loop and no process per file, so the session brief can run it
# over every source file.
hotspot_scan() {
  hs_rules=$(mktemp "${TMPDIR:-/tmp}/hot.XXXXXX") || return 0
  hotspot_rules "$1" > "$hs_rules"
  hs_at=$(hotspot_warn_at "$1")
  hs_tab=$(printf '\t')
  set -f
  printf '%s\n' "$2" | tr -d '\r' | tr '\\' '/' | while IFS="$hs_tab" read -r hs_n hs_p; do
    [ -n "$hs_p" ] || continue
    hs_lim=""
    while read -r hs_kind hs_a hs_rest; do
      case "$hs_kind" in
        exempt) for hs_pat in $hs_a $hs_rest; do case "$hs_p" in $hs_pat) hs_lim=0; break ;; esac; done ;;
        limit) for hs_pat in $hs_rest; do case "$hs_p" in $hs_pat) hs_lim=$hs_a; break ;; esac; done ;;
      esac
      [ -z "$hs_lim" ] || break
    done < "$hs_rules"
    [ -n "$hs_lim" ] && [ "$hs_lim" -gt 0 ] || continue
    if [ "$hs_n" -gt "$hs_lim" ]; then printf 'over\t%s\n' "$hs_p"
    elif [ $((hs_n * 100)) -ge $((hs_lim * hs_at)) ]; then printf 'near\t%s\n' "$hs_p"; fi
  done
  set +f
  rm -f "$hs_rules"
  return 0
}
