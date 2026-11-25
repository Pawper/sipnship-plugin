#!/bin/sh
# The plan reads areas the way publish-round.sh does (specs/010-work, "Areas"),
# so what it proposes can be published as it is: a ready issue in an area the
# running round's unit owns is a hold behind that unit, never a dispatch, and
# two units in one area are one unit. Pure: every function takes text and
# prints text; tests/run.sh covers each. Needs areas-lib.sh (round_areas,
# running_units).

# unit_areas LIST FILES
# The area names (comma separated) of the comma-separated FILES, by the
# project's areas LIST (the areas file's text). Nothing when LIST is empty or
# a file is on no area. A file on no area is left out and the others still
# count: round_areas refuses the whole value for one unplaced path, which
# would leave a unit with no area at all, and a plan that sees none proposes
# a start the publisher then refuses.
unit_areas() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  # One process for the whole unit, never one per file: a unit of many files cost hundreds of starts, which on Windows stalled the plan after "round proposed" (#1926).
  printf '%s\n' "$2" | AREA_LIST=$1 awk -F, '
    BEGIN {
      n = split(ENVIRON["AREA_LIST"], ln, "\n")
      for (l = 1; l <= n; l++) {
        s = ln[l]; gsub(/\r/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (s == "" || s ~ /^#/) continue
        k = split(s, w, /[ \t]+/); na++; name[na] = w[1]; np[na] = 0
        for (i = 2; i <= k; i++) { sub(/^\.\//, "", w[i]); path[na, ++np[na]] = w[i] }
      }
    }
    {
      for (f = 1; f <= NF; f++) {
        v = $f; gsub(/^[ \t]+|[ \t]+$/, "", v); sub(/^\.\//, "", v)
        if (v == "") continue
        for (i = 1; i <= na; i++) {
          hit = (v == name[i])
          for (j = 1; j <= np[i] && !hit; j++) { p = path[i, j]; if (index(v, p) == 1 || (v ~ /[/]$/ && index(p, v) == 1)) hit = 1 }
          if (hit && !(name[i] in seen)) { seen[name[i]] = 1; out = out (out == "" ? "" : ",") name[i] }
        }
      }
    }
    END { print out }'
}

# broad_free_files FILES
# The comma-separated FILES without a project's shared docs folder (docs/ and what is in it). Many unrelated issues name a file there (a mission, a plan, a decision), so such a file places an issue in an area for holds but never joins two issues into one unit (#1891). A spec folder is not broad.
broad_free_files() {
  printf '%s\n' "$1" | tr ',' '\n' | awk '$0 != "" && $0 !~ /^(\.\/)?docs(\/|$)/' | paste -sd, -
}

# areas_meet A B
# "yes" when two comma separated lists of area names share one.
areas_meet() {
  printf '%s\n%s\n' "$1" "$2" | awk '
    NR == 1 { n = split($0, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") x[a[i]] = 1; next }
    { n = split($0, b, ","); for (i = 1; i <= n; i++) if (b[i] != "" && (b[i] in x)) hit = 1 }
    END { print (hit ? "yes" : "no") }'
}

# area_units LIST UNITS RUNNING TITLES
# UNITS are plan_units' lines (unit NUMBERS TITLES WHY FILES, hold NUMBER TITLE
# After: TITLE), RUNNING running_units' lines ("ISSUES<TAB>AREAS", commas), TITLES
# "NUMBER<TAB>TITLE" lines. Prints the lines the round can publish:
#   a unit in an area a running unit owns (and not part of it) becomes one
#     "hold<TAB>NUMBER<TAB>TITLE<TAB>After: RUNNING TITLE" per issue;
#   units that share an area become one unit (the first's place, issues in
#     order, why "both change the X area");
#   every other line passes as it came.
# With no areas LIST the lines pass unchanged.
# PLAN_LISTED (environment, space separated) names the issues whose first line
# lists their files, the way plan_units reads it: a unit whose every issue
# lists its files relies on the literal check plan_units already made, and is
# never held behind a running unit, nor bundled with another unit, by area
# alone (#2452); only a unit with a guessed issue still reads areas for that.
area_units() {
  if [ -z "$1" ]; then printf '%s\n' "$2"; return 0; fi
  au_us=$(printf '\037')
  au_lines=$(printf '%s\n' "$2" | tr '\t' '\037' | while IFS="$au_us" read -r au_k au_n au_t au_w au_f; do
    [ -n "$au_k" ] || continue
    if [ "$au_k" = unit ]; then printf 'unit\t%s\t%s\t%s\t%s\t%s\t%s\n' "$au_n" "$au_t" "$au_w" "$au_f" "$(unit_areas "$1" "$au_f")" "$(unit_areas "$1" "$(broad_free_files "$au_f")")"
    else printf '%s\t%s\t%s\t%s\t\t\n' "$au_k" "$au_n" "$au_t" "$au_w"; fi
  done)
  { printf '%s\n' "$3" | sed 's/^/R\t/'; printf '%s\n' "$4" | sed 's/^/T\t/'; printf '%s\n' "$au_lines" | sed 's/^/U\t/'; } | tr -d '\r' | awk -F'\t' '
    function find(i) { while (par[i] != i) i = par[i]; return i }
    function asked(nums,   t) { split(nums, t, " "); return index(" " ENVIRON["ASKED_ISSUES"] " ", " " t[1] " ") > 0 }
    function listed_all(nums,   t, k, i) { k = split(nums, t, " "); if (k == 0) return 0; for (i = 1; i <= k; i++) if (t[i] == "" || index(" " ENVIRON["PLAN_LISTED"] " ", " " t[i] " ") == 0) return 0; return 1 }
    function meet(a, b,   x, y, i, j, nx, ny) {
      nx = split(a, x, ","); ny = split(b, y, ",")
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] != "" && x[i] == y[j]) return x[i]
      return ""
    }
    function inrun(nums, issues,   x, y, i, j, nx, ny) {
      nx = split(nums, x, " "); gsub(/,/, " ", issues); ny = split(issues, y, " ")
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] == y[j]) return 1
      return 0
    }
    $1 == "R" && $2 != "" { r++; ri[r] = $2; ra[r] = $3 }
    $1 == "T" && $2 != "" { tt[$2] = $3 }
    $1 == "U" && $2 == "unit" { n++; num[n] = $3; ttl[n] = $4; why[n] = $5; fl[n] = $6; ar[n] = $7; mar[n] = $8; sz[n] = split($3, szt, " "); par[n] = n; line[++L] = "u" n }
    $1 == "U" && $2 != "unit" && $2 != "" { line[++L] = "o"; other[L] = $2 "\t" $3 "\t" $4 "\t" $5 }
    END {
      cap = (ENVIRON["PLAN_BUNDLE_MAX"] + 0 > 0) ? ENVIRON["PLAN_BUNDLE_MAX"] + 0 : 4  # a bundle is a few issues; past it the rest stay loose units (#1891)
      bmax = (ENVIRON["PLAN_BROAD_AREAS"] + 0 > 0) ? ENVIRON["PLAN_BROAD_AREAS"] + 0 : 6
      for (i = 1; i <= n; i++) {
        held[i] = ""
        if (listed_all(num[i])) continue  # its own Touches line is the literal truth; areas alone never hold it (#2452)
        # A unit that names no files is only guessed (a bare folder such as plugin/), and a guess that reaches many areas is every area at once: it clashes with whatever runs and the publisher refuses the whole round. It is held alone, so the rest of the round publishes (#2766).
        if (split(ar[i], broad, ",") > bmax) { held[i] = "Its files are not known: it names none, and the guess spans " split(ar[i], broad, ",") " areas. The agent'"'"'s turn: name its files on its first line (Touches: PATH PATH) to place it"; continue }
        for (k = 1; k <= r; k++) if (!inrun(num[i], ri[k]) && (am = meet(ar[i], ra[k])) != "") {
          first = ri[k]; sub(/[ ,].*/, "", first)
          wo = ri[k]; gsub(/[ ,]+/, " ", wo)  # the issues of the running unit, so a reader can tell when the wait ended
          held[i] = "After: " (first in tt && tt[first] != "" ? tt[first] : "#" first) " [area: " am "] (after: " wo ")"  # the area the two share, so a wrong hold is seen for what it is (#2444)
          break
        }
      }
      for (i = 1; i <= n; i++) if (held[i] == "") for (j = i + 1; j <= n; j++) if (held[j] == "") {
        if (listed_all(num[i]) || listed_all(num[j])) continue  # a unit with its own file list is never bundled with another by area alone (#2452)
        s = meet(mar[i], mar[j])
        # an issue asked for by name is bundled by the files it shares like any other, with asked and unasked issues alike (#2122)
        if (s != "") { a = find(i); b = find(j); if (a != b && sz[a] + sz[b] <= cap) { par[b] = a; sz[a] += sz[b]; if (sh[a] == "") sh[a] = s } }
      }
      for (i = 1; i <= n; i++) if (held[i] == "") {
        g = find(i)
        mem[g] = mem[g] (mem[g] == "" ? "" : " ") num[i]
        tl[g] = tl[g] (tl[g] == "" ? "" : " | ") ttl[i]
        cnt[g] += split(num[i], tmp, " ")
        fs[g] = fs[g] (fs[g] == "" || fl[i] == "" ? "" : ",") fl[i]
        if (why[g] == "" && why[i] != "") why[g] = why[i]
      }
      for (x = 1; x <= L; x++) {
        l = line[x]
        if (substr(l, 1, 1) == "o") { print other[x]; continue }
        i = substr(l, 2) + 0
        if (held[i] != "") {
          m = split(num[i], ns, " "); q = split(ttl[i], ts, " \\| ")
          for (k = 1; k <= m; k++) printf "hold\t%s\t%s\t%s\n", ns[k], (q == m ? ts[k] : ttl[i]), held[i]
          continue
        }
        g = find(i)
        if (g != i) continue
        w = why[g]
        if (cnt[g] > split(num[i], tmp, " ") && sh[g] != "") w = (cnt[g] == 2 ? "both" : "all " cnt[g]) " change the " sh[g] " area"
        printf "unit\t%s\t%s\t%s\t%s\n", mem[g], tl[g], w, fs[g]
      }
    }'
}

# dispatch_area_holds ROUND UNITS LIST
# ROUND is apply_units' lines: "dispatch NUMS<TAB>TITLES[<TAB>Why together:
# ...][<TAB>First: ...]", "hold NUM<TAB>TITLE<TAB>REASON", "defer ...",
# "stop: ...". UNITS are the same plan_units/area_units lines the round's
# dispatches were built from ("unit<TAB>NUMS<TAB>TITLES<TAB>WHY<TAB>FILES").
# LIST is the project's areas file's text (round_areas' LIST).
#
# apply_units ranks and fills the round's slots without reading the
# project's named areas, so two dispatches it kept can still share one (an
# asked-for unit and a priority unit, say, both in "queue"), which
# publish-round.sh refuses outright (#2136). Walked in the round's own
# order (a fix for main first, then what was asked for, then a priority,
# then the rest), the first dispatch in an area keeps its place; a later
# one in the same area becomes a hold behind it instead, naming it, so the
# round the plan builds always publishes. With no areas list, or a dispatch
# on no area, nothing changes: publish-round.sh then reads each unit's own
# files as its area, and a unit on no area shares one with nothing.
dispatch_area_holds() {
  if [ -z "$3" ]; then printf '%s\n' "$1"; return 0; fi
  da2_pairs=""
  while IFS= read -r da2_nums; do
    [ -n "$da2_nums" ] || continue
    da2_files=$(printf '%s\n' "$2" | awk -F'\t' -v k="$da2_nums" '$1 == "unit" && $2 == k { print $5; exit }')
    da2_pairs="${da2_pairs}${da2_nums}	$(unit_areas "$3" "$da2_files")	${da2_files}
"
  done <<EOF_DA2
$(printf '%s\n' "$1" | awk -F'\t' '$0 ~ /^dispatch [0-9]/ { n = $1; sub(/^dispatch /, "", n); print n }')
EOF_DA2
  { printf '%s\n' "$da2_pairs" | sed 's/^/A\t/'; printf '%s\n' "$1" | sed 's/^/R\t/'; } | tr -d '\r' | awk -F'\t' '
    function meet(a, b,   x, y, i, j, nx, ny) {
      nx = split(a, x, ","); ny = split(b, y, ",")
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] != "" && x[i] == y[j]) return x[i]
      return ""
    }
    function listed_all(nums,   t, k, i) { k = split(nums, t, " "); if (k == 0) return 0; for (i = 1; i <= k; i++) if (t[i] == "" || index(" " ENVIRON["PLAN_LISTED"] " ", " " t[i] " ") == 0) return 0; return 1 }
    function sharefile(a, b,   x, y, i, j, nx, ny, p, q) {
      nx = split(a, x, ","); ny = split(b, y, ",")  # a folder counts for what lies under it
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) {
        p = x[i]; q = y[j]; gsub(/^\.\/|\/$/, "", p); gsub(/^\.\/|\/$/, "", q)
        if (p != "" && q != "" && (p == q || index(p, q "/") == 1 || index(q, p "/") == 1)) return (length(p) >= length(q) ? p : q)
      }
      return ""
    }
    $1 == "A" && $2 != "" { na++; anum[na] = $2; aare[na] = $3; afil[na] = $4 }
    $1 != "R" { next }
    {
      line = $0; sub(/^R\t/, "", line)
      if (line !~ /^dispatch [0-9]/) { print line; next }
      split(line, f, "\t")
      nums = f[1]; sub(/^dispatch /, "", nums)
      area = ""; files = ""
      for (i = 1; i <= na; i++) if (anum[i] == nums) { area = aare[i]; files = afil[i]; break }
      lst = listed_all(nums); won = ""; how = ""  # two listed dispatches are held only for a file they share, never by area alone (#2535)
      for (g = 1; g <= ng && won == ""; g++) {
        if (lst && glst[g]) { if ((am = sharefile(files, gfil[g])) != "") { won = g; how = "shares: " am } }
        else if (area != "" && (am = meet(area, garea[g])) != "") { won = g; how = "area: " am }
      }
      if (won != "") {
        m = split(nums, ns, " "); q = split(f[2], ts, " \\| ")
        for (k = 1; k <= m; k++) printf "hold %s\t%s\tAfter: %s [%s] (after: %s)\n", ns[k], (q == m ? ts[k] : f[2]), gtitle[won], how, gnums[won]
        next
      }
      ng++; garea[ng] = area; gfil[ng] = files; glst[ng] = lst; gtitle[ng] = f[2]; sub(/ \| .*/, "", gtitle[ng]); gnums[ng] = nums
      print line
    }'
}

# held_area_holds LIST UNITS HELD PUBLISHED TITLES
# HELD are published_held_areas' lines ("ISSUES<TAB>WAITSON<TAB>AREAS"),
# PUBLISHED published_holds' lines (the held issues still true). A unit in an
# area a held issue of the last published round names, when that issue does not
# wait on it, is refused by publish-round.sh; the issue follows the held one
# instead: one "hold<TAB>NUMBER<TAB>TITLE<TAB>After: HELD TITLE" per issue, so
# an issue the builder asked for by name keeps its place. Other lines pass.
held_area_holds() {
  if [ -z "$1" ] || [ -z "$3" ] || [ -z "$4" ]; then printf '%s\n' "$2"; return 0; fi
  hh_us=$(printf '\037')
  hh_lines=$(printf '%s\n' "$2" | tr '\t' '\037' | while IFS="$hh_us" read -r hh_k hh_n hh_t hh_w hh_f; do
    [ -n "$hh_k" ] || continue
    if [ "$hh_k" = unit ]; then printf 'unit\t%s\t%s\t%s\t%s\t%s\n' "$hh_n" "$hh_t" "$hh_w" "$hh_f" "$(unit_areas "$1" "$hh_f")"
    else printf '%s\t%s\t%s\t%s\t\t\n' "$hh_k" "$hh_n" "$hh_t" "$hh_w"; fi
  done)
  { printf '%s\n' "$3" | sed 's/^/H\t/'; printf '%s\n' "$4" | cut -f2 | sed 's/^/P\t/'; printf '%s\n' "$5" | sed 's/^/T\t/'; printf '%s\n' "$hh_lines" | sed 's/^/U\t/'; } | tr -d '\r' | awk -F'\t' '
    function has(list, nums,   x, y, i, j, nx, ny) {
      gsub(/,/, " ", list); gsub(/,/, " ", nums)
      nx = split(list, x, " "); ny = split(nums, y, " ")
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] != "" && x[i] == y[j]) return 1
      return 0
    }
    function meet(a, b,   x, y, i, j, nx, ny) {
      nx = split(a, x, ","); ny = split(b, y, ",")
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] != "" && x[i] == y[j]) return x[i]
      return ""
    }
    function listed_all(nums,   t, k, i) { k = split(nums, t, " "); if (k == 0) return 0; for (i = 1; i <= k; i++) if (t[i] == "" || index(" " ENVIRON["PLAN_LISTED"] " ", " " t[i] " ") == 0) return 0; return 1 }
    $1 == "H" && $2 != "" { h++; hi[h] = $2; hw[h] = $3; ha[h] = $4 }
    $1 == "P" && $2 != "" { pub[$2] = 1 }
    $1 == "T" && $2 != "" { tt[$2] = $3 }
    $1 == "U" && $2 != "" { u[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        split(substr(u[i], 3), f, "\t"); nums = f[2]; by = ""
        if (f[1] == "unit") for (k = 1; k <= h; k++) {
          first = hi[k]; sub(/,.*/, "", first)
          if (listed_all(nums) || !(first in pub) || has(hw[k], nums) || (am = meet(f[6], ha[k])) == "") continue
          by = "After: " (first in tt && tt[first] != "" ? tt[first] : "#" first) " [area: " am "] (after: " first ")"; break
        }
        if (by == "") { printf "%s\t%s\t%s\t%s", f[1], f[2], f[3], f[4]; if (f[1] == "unit") printf "\t%s", f[5]; printf "\n"; continue }
        m = split(nums, ns, " "); q = split(f[3], ts, " \\| ")
        for (k = 1; k <= m; k++) printf "hold\t%s\t%s\t%s\n", ns[k], (q == m ? ts[k] : f[3]), by
      }
    }'
}

# title_area_files TITLE AREAS
# An issue whose body names no path is placed by its title: the first path of
# every area whose name (a hyphen read as a space) the title says as a whole
# word, comma separated. Nothing when AREAS is empty or no name is said.
title_area_files() {
  [ -n "$2" ] || return 0
  printf '%s\n' "$2" | tr -d '\r' | awk -v t="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '
    BEGIN { t = " " t " "; gsub(/[^a-z0-9]+/, " ", t) }
    /^#/ || NF < 2 { next }
    { name = tolower($1); gsub(/-/, " ", name); if (index(t, " " name " ")) out = out (out == "" ? "" : ",") $2 }
    END { print out }'
}

# unplaced_holds UNITS GUESSES RUNNING TITLES
# GUESSES are the plan's "NUMBER<TAB>TITLE<TAB>FILES" lines; an issue whose
# FILES are empty has no area the plan can see. While a unit is running
# (RUNNING, running_units' lines) such an issue is not dispatched blind: its
# unit line becomes a hold that says its area is unknown and names the running
# unit. With nothing running every line passes as it came. TITLES are
# "NUMBER<TAB>TITLE" lines.
unplaced_holds() {
  if [ -z "$3" ]; then printf '%s\n' "$1"; return 0; fi
  { printf '%s\n' "$2" | sed 's/^/G\t/'; printf '%s\n' "$3" | sed 's/^/R\t/'; printf '%s\n' "$4" | sed 's/^/T\t/'; printf '%s\n' "${5:-}" | sed 's/^/H\t/'; printf '%s\n' "$1" | sed 's/^/U\t/'; } | tr -d '\r' | awk -F'\t' '
    $1 == "G" && $2 != "" && $4 == "" { none[$2] = 1 }
    $1 == "H" && $2 != "" { hp[$2] = $3 }
    $1 == "R" && $2 != "" && first == "" { first = $2; sub(/[ ,].*/, "", first); runall = $2; gsub(/[ ,]+/, " ", runall) }
    $1 == "T" && $2 != "" { tt[$2] = $3 }
    $1 == "U" && $2 != "" { u[++n] = $0 }
    END {
      run = (first in tt && tt[first] != "") ? "\"" tt[first] "\"" : "#" first
      for (i = 1; i <= n; i++) {
        split(u[i], f, "\t"); all = (f[2] == "unit")
        m = split(f[3], ns, " ")
        if (all) for (k = 1; k <= m; k++) if (!(ns[k] in none)) all = 0
        if (!all) { print substr(u[i], 3); continue }
        q = split(f[4], ts, " \\| ")
        for (k = 1; k <= m; k++) {
          if (ns[k] in hp) printf "hold\t%s\t%s\tIts pull request (#%s) is held for your read; no agent is started on it\n", ns[k], (q == m ? ts[k] : f[4]), hp[ns[k]]
          else printf "hold\t%s\t%s\tIts area is not known: it names no file or area, and %s is running. The agent'"'"'s turn: name its files on its first line to place it (after: %s)\n", ns[k], (q == m ? ts[k] : f[4]), run, runall
        }
      }
    }'
}
