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
# a file is on no area.
unit_areas() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  printf '%s\n' "$(round_areas "$1" "unit: 1 | areas: $2")" | sed -n 's/^unit: 1 | areas: //p' | tr -d ' '
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
area_units() {
  if [ -z "$1" ]; then printf '%s\n' "$2"; return 0; fi
  au_us=$(printf '\037')
  au_lines=$(printf '%s\n' "$2" | tr '\t' '\037' | while IFS="$au_us" read -r au_k au_n au_t au_w au_f; do
    [ -n "$au_k" ] || continue
    if [ "$au_k" = unit ]; then printf 'unit\t%s\t%s\t%s\t%s\t%s\n' "$au_n" "$au_t" "$au_w" "$au_f" "$(unit_areas "$1" "$au_f")"
    else printf '%s\t%s\t%s\t%s\t\t\n' "$au_k" "$au_n" "$au_t" "$au_w"; fi
  done)
  { printf '%s\n' "$3" | sed 's/^/R\t/'; printf '%s\n' "$4" | sed 's/^/T\t/'; printf '%s\n' "$au_lines" | sed 's/^/U\t/'; } | tr -d '\r' | awk -F'\t' '
    function find(i) { while (par[i] != i) i = par[i]; return i }
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
    $1 == "U" && $2 == "unit" { n++; num[n] = $3; ttl[n] = $4; why[n] = $5; fl[n] = $6; ar[n] = $7; par[n] = n; line[++L] = "u" n }
    $1 == "U" && $2 != "unit" && $2 != "" { line[++L] = "o"; other[L] = $2 "\t" $3 "\t" $4 "\t" $5 }
    END {
      for (i = 1; i <= n; i++) {
        held[i] = ""
        for (k = 1; k <= r; k++) if (!inrun(num[i], ri[k]) && meet(ar[i], ra[k]) != "") {
          first = ri[k]; sub(/[ ,].*/, "", first)
          held[i] = "After: " (first in tt && tt[first] != "" ? tt[first] : "#" first)
          break
        }
      }
      for (i = 1; i <= n; i++) if (held[i] == "") for (j = i + 1; j <= n; j++) if (held[j] == "") {
        s = meet(ar[i], ar[j])
        if (s != "") { a = find(i); b = find(j); if (a != b) { par[b] = a; if (sh[a] == "") sh[a] = s } }
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
