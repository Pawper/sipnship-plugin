#!/bin/sh
# The project's areas (specs/010-work, "Areas"): the parts of a project that a
# round keeps apart, so two units in the same files are seen as such whatever
# words they use. The list is one file the project keeps, `.claude/areas.txt`:
#
#   # NAME     the paths it covers, separated by spaces; a folder ends in /
#   watering   specs/030-watering/ src/schedule.ts src/water/
#   beds       specs/031-beds/ src/beds/
#
# A path may also be the start of file names ("src/water-" covers
# src/water-log.ts). A round names a unit's areas by name, or by a path inside
# one: the path becomes every area it falls in, or that falls in it. Pure:
# every function takes text and prints text; tests/run.sh covers each.

# round_areas LIST ROUND [WHERE]
# LIST is the areas file's text, ROUND the round file's. Prints ROUND with
# each unit, hold and apart line's `areas:` (or the older `files:`) field
# rewritten to the area names it means, or one "error<TAB>MESSAGE" line when
# a value is on no area, the list is empty, or a unit or hold names no area.
# WHERE names the list in the message (default .claude/areas.txt).
round_areas() {
  printf '%s\n' "$2" | AREA_LIST=$1 AREA_WHERE=${3:-.claude/areas.txt} awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function bad(msg) { print "error\t" msg; failed = 1; exit }
    function resolve(v,   i, j, out, hit) {
      v = trim(v); sub(/^\.\//, "", v)
      if (v in named) return v
      out = ""
      for (i = 1; i <= na; i++) {
        hit = 0
        for (j = 1; j <= np[i]; j++) {
          p = path[i, j]
          if (index(v, p) == 1 || index(p, v) == 1) hit = 1
        }
        if (hit) out = out (out == "" ? "" : ",") name[i]
      }
      return out
    }
    BEGIN {
      where = ENVIRON["AREA_WHERE"]
      n = split(ENVIRON["AREA_LIST"], ln, "\n")
      for (l = 1; l <= n; l++) {
        s = ln[l]; gsub(/\r/, "", s); s = trim(s)
        if (s == "" || s ~ /^#/) continue
        k = split(s, w, /[ \t]+/)
        na++; name[na] = w[1]; named[w[1]] = 1; np[na] = 0
        for (i = 2; i <= k; i++) { sub(/^\.\//, "", w[i]); path[na, ++np[na]] = w[i] }
      }
      if (na == 0) bad("this project keeps no list of areas at " where "; write one, an area a line: its name, then the paths it covers")
    }
    /^[ \t]*(unit|hold|apart):/ {
      kind = $0; sub(/:.*/, "", kind); kind = trim(kind)
      np2 = split($0, part, /\|/); out = part[1]; seen = 0
      for (q = 2; q <= np2; q++) {
        s = trim(part[q]); key = s; sub(/:.*/, "", key); key = tolower(trim(key))
        if (key != "areas" && key != "files") { out = out "| " s " "; continue }
        v = trim(substr(s, index(s, ":") + 1)); m = split(v, vs, ","); names = ""; delete got
        for (i = 1; i <= m; i++) {
          if (trim(vs[i]) == "") continue
          r = resolve(vs[i])
          if (r == "") bad(trim(vs[i]) " is not an area on the list in " where "; name one of its areas, or a path inside one")
          c = split(r, rs, ",")
          for (j = 1; j <= c; j++) if (!(rs[j] in got)) { got[rs[j]] = 1; names = names (names == "" ? "" : ", ") rs[j] }
        }
        if (names != "") { out = out "| areas: " names " "; seen = 1 }
      }
      who = part[1]; sub(/^[^:]*:/, "", who)
      if (!seen && kind != "apart") bad("the " kind " " trim(who) " names no area; add | areas: NAME, from the list in " where)
      sub(/ $/, "", out); buf = buf out "\n"; next
    }
    { buf = buf $0 "\n" }
    END { if (!failed) printf "%s", buf }'
}

# area_problem ROUND RUNNING
# ROUND is round_areas' output; RUNNING is running_units' (below). The
# first way the round breaks the area rule, in words that say what to do, or
# nothing when it keeps it:
#   two units of the round share an area: bundle them, or hold one behind the
#     other;
#   a held unit shares an area with a unit it does not wait on;
#   a unit shares an area with a running unit it is not part of: give its
#     issues to that unit, or hold them behind it.
# An `apart:` line naming an issue of each side, with its why, lets the two
# run side by side: the reason is stated, and the Work tab shows it.
area_problem() {
  printf '%s\n' "$1" | AREA_RUNNING=$2 awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function nums(s) { s = trim(s); gsub(/[#,]/, " ", s); gsub(/[ \t]+/, " ", s); return trim(s) }
    function field(line, want,   k, i, s, key) {
      k = split(line, f, /\|/)
      for (i = 2; i <= k; i++) { s = trim(f[i]); key = s; sub(/:.*/, "", key); if (tolower(trim(key)) == want) return trim(substr(s, index(s, ":") + 1)) }
      return ""
    }
    function meets(a, b,   x, y, i, j, nx, ny) {
      nx = split(a, x, " "); ny = split(b, y, " ")
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] == y[j]) return 1
      return 0
    }
    function shared(a, b,   x, y, i, j, nx, ny) {
      nx = split(a, x, /, */); ny = split(b, y, /, */)
      for (i = 1; i <= nx; i++) for (j = 1; j <= ny; j++) if (x[i] != "" && x[i] == y[j]) return x[i]
      return ""
    }
    function apart(a, b,   k) { for (k = 1; k <= nap; k++) if (meets(ap[k], a) && meets(ap[k], b)) return 1; return 0 }
    function hashes(s) { gsub(/ /, ", #", s); return "#" s }
    function say(msg) { print msg; done = 1; exit }
    /^[ \t]*unit:/ { s = $0; sub(/^[ \t]*unit:/, "", s); sub(/\|.*/, "", s); nu++; ui[nu] = nums(s); ua[nu] = field($0, "areas"); next }
    /^[ \t]*hold:/ { s = $0; sub(/^[ \t]*hold:/, "", s); sub(/\|.*/, "", s); nh++; hi[nh] = nums(s); ha[nh] = field($0, "areas"); hw[nh] = nums(field($0, "after")); next }
    /^[ \t]*apart:/ {
      s = $0; sub(/^[ \t]*apart:/, "", s); sub(/\|.*/, "", s)
      if (field($0, "why") == "") say("the apart line " trim(s) " gives no why; say why those issues run apart with | why: ...")
      nap++; ap[nap] = nums(s); next
    }
    END {
      if (done) exit
      for (i = 1; i <= nu; i++) for (j = i + 1; j <= nu; j++) {
        a = shared(ua[i], ua[j])
        if (a != "" && !apart(ui[i], ui[j])) say(hashes(ui[i]) " and " hashes(ui[j]) " are two units in one area, " a "; bundle them into one unit, or hold one behind the other (hold: " ui[j] " | after: " ui[i] " | areas: " a "); to run them side by side anyway, say why on an apart: line")
      }
      for (h = 1; h <= nh; h++) for (i = 1; i <= nu; i++) {
        a = shared(ha[h], ua[i])
        if (a != "" && !meets(hw[h], ui[i]) && !apart(hi[h], ui[i])) say("the held " hashes(hi[h]) " shares the area " a " with " hashes(ui[i]) " but waits on something else; hold it after that unit (after: " ui[i] ")")
      }
      nr = split(ENVIRON["AREA_RUNNING"], rl, "\n")
      for (r = 1; r <= nr; r++) {
        if (rl[r] == "") continue
        split(rl[r], rf, "\t"); ri = rf[1]; gsub(/,/, " ", ri)
        for (i = 1; i <= nu; i++) {
          if (meets(ui[i], ri)) continue
          a = shared(ua[i], rf[2])
          if (a != "" && !apart(ui[i], ri)) say("the unit " hashes(ui[i]) " is in the area " a ", which the running unit " hashes(ri) " owns; give it to that unit (add it to the line of that unit), or hold it after that unit (hold: " ui[i] " | after: " ri " | areas: " a "), or say why it runs apart on an apart: line")
        }
      }
    }'
}

# running_units COMMENTS IN_PROGRESS
# COMMENTS are the drive issue's comment bodies, one per line. IN_PROGRESS is
# the open issues labeled In progress, one number per line. Prints each unit
# of the latest started round that still has an issue in progress, one
# "ISSUES<TAB>AREAS" line, both comma separated: the areas a running unit
# owns, so publish-round.sh can give new work in them to that unit or hold it
# behind it. Nothing when no round runs.
# A unit also runs while its pull request is open, whatever State its issues
# show (as running_round counts it): the optional third argument is the open
# pull requests' numbers, one per line, and a unit whose "pr" is among them runs.
running_units() {
  ru_m=$(printf '%s\n' "$1" | tr -d '\r' | grep -F 'sipnship-proposal {"status":"started"' | tail -n 1 \
    | sed 's/.*sipnship-proposal {"status":"started",//; s/"held":.*//')
  [ -n "$ru_m" ] || return 0
  printf '%s\n' "$ru_m" | awk -v ip="$(printf '%s\n' "$2" | tr -d '\r' | tr '\n' ' ')" -v op="$(printf '%s\n' "${3:-}" | tr -d '\r' | tr '\n' ' ')" '
    BEGIN {
      n = split(ip, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") live[a[i]] = 1
      n = split(op, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") opn[a[i]] = 1
    }
    {
      k = split($0, part, /\{"issues":/)
      for (p = 2; p <= k; p++) {
        u = part[p]
        if (!match(u, /^\[[0-9, ]*\]/)) continue
        is = substr(u, 2, RLENGTH - 2); gsub(/ /, "", is)
        ar = ""
        if (match(u, /"areas":\[[^]]*\]/)) { ar = substr(u, RSTART + 9, RLENGTH - 10); gsub(/"/, "", ar) }
        m = split(is, ns, ","); on = 0
        pr = ""; if (match(u, /"pr":[0-9]+/)) pr = substr(u, RSTART + 5, RLENGTH - 5)
        if (pr != "" && (pr in opn)) on = 1
        for (i = 1; i <= m; i++) if (ns[i] in live) on = 1
        if (on) print is "\t" ar
      }
    }'
}
