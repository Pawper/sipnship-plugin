#!/bin/sh
# The plan publishes its own proposal (#2101): the round it builds is written
# as a round file and published to the Work tab by publish-round.sh in the same
# run, with no model in between, so what the tab shows is what the plan made
# and what a dispatch starts. A run with nothing new still publishes that it
# looked. Sourced by plan.sh after round-sizing-lib.sh and area-plan-lib.sh;
# round_file is pure and tests/run.sh covers it.

# round_file ROUND UNITS AREAS ISSUES SIZED [STALL]
# ROUND is the plan's goal lines, UNITS the plan_units/area_units lines
# ("unit<TAB>NUMS<TAB>TITLES<TAB>WHY<TAB>FILES"), AREAS the project's areas
# list (empty: each unit's own files stand for its areas), ISSUES the open
# issues' numbers, one a line, so a pull request's own hold line is never read
# as an issue's, SIZED the plan's sized words. Prints the round file:
#   status: proposed
#   unit: 12 14 | why: both change ... | areas: watering   one per dispatch goal
#   hold: 16 | why: ... | after: 12                         one per issue held
#   sized: ...
#   stall: ...                                              when every ready issue is held, the plan's stall words
# An issue is named once: a unit first, then the first hold that names it. A
# unit on no area of the list says `areas: none`; a hold says none too, since
# it starts nothing and is planned again next run.
round_file() {
  { printf '%s\n' "$2" | sed 's/^/U\t/'; printf '%s\n' "$4" | sed 's/^/I\t/'; printf '%s\n' "$1" | sed 's/^/R\t/'; } | tr -d '\r' | RF_AREAS=$3 awk -F'\t' -v sized="$5" -v stall="${6:-}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function clean(s) { gsub(/\|/, "/", s); gsub(/[ \t]+/, " ", s); return trim(s) }
    function cap1(s) { return toupper(substr(s, 1, 1)) substr(s, 2) }
    function areas_of(files,   n, f, i, j, v, hit, out, seen) {
      out = ""; n = split(files, f, ",")
      for (i = 1; i <= n; i++) {
        v = trim(f[i]); sub(/^\.\//, "", v); if (v == "" || v == "@tooling") continue
        if (!na) { if (!(v in seen)) { seen[v] = 1; out = out (out == "" ? "" : ", ") v }; continue }
        for (a = 1; a <= na; a++) {
          hit = (v == aname[a])
          for (j = 1; j <= anp[a] && !hit; j++) if (index(v, apath[a, j]) == 1 || index(apath[a, j], v) == 1) hit = 1
          if (hit && !(aname[a] in seen)) { seen[aname[a]] = 1; out = out (out == "" ? "" : ", ") aname[a] }
        }
      }
      return out == "" ? "none" : out
    }
    function fresh(nums,   n, x, i, out) { n = split(nums, x, /[ ,#]+/); out = ""; for (i = 1; i <= n; i++) if (x[i] ~ /^[0-9]+$/ && !(x[i] in used)) { used[x[i]] = 1; out = out (out == "" ? "" : " ") x[i] }; return out }
    BEGIN {
      n = split(ENVIRON["RF_AREAS"], ln, "\n")
      for (l = 1; l <= n; l++) {
        s = trim(ln[l]); if (s == "" || s ~ /^#/) continue
        k = split(s, w, /[ \t]+/); na++; aname[na] = w[1]; anp[na] = 0
        for (i = 2; i <= k; i++) { sub(/^\.\//, "", w[i]); apath[na, ++anp[na]] = w[i] }
      }
      print "status: proposed"
    }
    $1 == "U" && $2 == "unit" { files[$3] = $6; next }
    $1 == "I" && $2 ~ /^[0-9]+$/ { issue[$2] = 1; next }
    $1 != "R" { next }
    {
      line = $0; sub(/^R\t/, "", line); sub(/^[0-9]+\. /, "", line)
      split(line, f, "\t")
      if (f[1] ~ /^dispatch [0-9]/) {
        nums = substr(f[1], 10); why = ""
        for (i = 2; i in f; i++) if (f[i] ~ /^Why together: /) why = substr(f[i], 15)
        nums = fresh(nums); if (nums == "") next
        out = "unit: " nums (why != "" ? " | why: " clean(why) : "") " | areas: " areas_of(files[substr(f[1], 10)])
        units[++nu] = out
        next
      }
      if (f[1] ~ /^hold [0-9]+$/) {
        num = substr(f[1], 6); if (!(num in issue)) next
        why = f[3]; after = ""
        if (match(why, /\(after: [0-9 ,#]+\)/)) { after = substr(why, RSTART + 8, RLENGTH - 9); gsub(/[#,]/, " ", after); after = trim(after); why = trim(substr(why, 1, RSTART - 1) substr(why, RSTART + RLENGTH)) }
        sub(/^Held in the last proposed round: /, "", why); sub(/; it takes no slot until that changes$/, "", why)
        if (why ~ /^Held in the last proposed round/) why = "Held in the last proposed round"
        if (why ~ /^After: /) why = "Waits for “" substr(why, 8) "” to land first, since it changes the same files"
        why = clean(why); if (why == "") why = "Held this round"
        held[num] = "hold: " num " | why: " cap1(substr(why, 1, 200)) (after != "" ? " | after: " after : "") " | areas: none"
        horder[++nh] = num
        next
      }
    }
    END {
      for (i = 1; i <= nu; i++) print units[i]
      for (i = 1; i <= nh; i++) { num = horder[i]; if (fresh(num) != "") print held[num] }
      if (sized != "") print "sized: " substr(clean(sized), 1, 160)
      sub(/^stall: /, "", stall); if (stall != "") print "stall: " substr(clean(stall), 1, 200)
    }'
  # A unit the limit left out is a hold saying so (round-sizing-lib.sh); its issues are in no unit.
  rf_defer=$(printf '%s\n' "$1" | sed 's/^[0-9]*\. //' | grep '^defer [0-9]* unit(s):')
  [ -z "$rf_defer" ] || deferred_holds "$rf_defer" | sed 's/$/ | areas: none/'
}

# publish_proposal ROUND UNITS AREAS FACTS SIZED [STALL]
# Writes the round file to .scratch/drive/round.txt and publishes it with
# publish-round.sh, then prints one line the round's report carries:
#   published: <publish-round's own line>
#   not published: <why, in its words>
# PLAN_PUBLISH=no (a dry run, and the suite) writes the file and publishes
# nothing, and says so. With no areas list the unit's own files are its areas,
# written beside the round file for publish-round.sh to read.
publish_proposal() {
  mkdir -p .scratch/drive 2>/dev/null
  pp_list=$3; pp_areas=.claude/areas.txt
  if [ -z "$pp_list" ]; then
    pp_areas=.scratch/drive/areas-guessed.txt
    { echo "# Guessed by the plan from each unit's files: this project keeps no list of areas."; echo "unplaced .scratch/drive/unplaced"
      printf '%s\n' "$2" | awk -F'\t' '$1 == "unit" { n = split($5, f, ","); for (i = 1; i <= n; i++) if (f[i] != "" && f[i] != "@tooling" && !(f[i] in s)) { s[f[i]] = 1; print f[i] " " f[i] } }'; } > "$pp_areas"
  fi
  round_file "$1" "$2" "$pp_list" "$(printf '%s\n' "$4" | awk -F'\t' '$1 == "issue" { print $2 }')" "$5" "${6:-}" > .scratch/drive/round.txt
  if [ "${PLAN_PUBLISH:-yes}" = no ]; then echo "not published: this run was told not to publish (a dry run); the round is in .scratch/drive/round.txt"; return 0; fi
  pp_out=$(sh "$here/publish-round.sh" --areas "$pp_areas" .scratch/drive/round.txt 2>&1); pp_rc=$?
  pp_first=$(printf '%s\n' "$pp_out" | sed -n 1p)
  if [ "$pp_rc" -eq 0 ]; then echo "published: $pp_first"; else echo "not published: ${pp_first:-publish-round.sh ended with $pp_rc}"; fi
}
