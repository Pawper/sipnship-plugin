#!/bin/sh
# Pure helpers for planning a round by files (specs/010-work, "The drive
# plans rounds by files"). Nothing here runs git or gh; every function takes
# text and prints text, and tests/run.sh covers each from fixtures.
#
# A guess is one line, tab separated:   NUMBER  TITLE  FILE,FILE,...
# A running unit is one line:           TITLE  FILE,FILE,...
# A path is a file, or a folder written with a trailing slash; a folder
# overlaps every path under it.

# body_paths BODY
# The paths a body names, one per line: anything with a slash that ends in
# a file extension or a slash, or starts with a known top folder. Links,
# issue references and prose like "and/or" are not paths. A spec folder
# named without a trailing slash (specs/010-work) becomes the folder.
body_paths() {
  printf '%s\n' "$1" | tr -d '\r' | tr ' \t`,;()[]<>"' '\n' | awk '
    {
      t = $0
      if (t ~ /:\/\// || t ~ /^#/ || t ~ /^\// || t !~ /\//) next
      if (t ~ /\/\//) next
      sub(/[.:!?]+$/, "", t)
      if (t ~ /^specs\/[0-9]+-[A-Za-z0-9_-]+$/) t = t "/"
      if (t ~ /\/$/ || t ~ /\.[A-Za-z0-9]+$/ || t ~ /^(specs|packages|plugin|scripts|docs|design|src|status)\//) {
        if (t ~ /^[A-Za-z0-9_.*\/-]+$/ && !(t in seen)) { seen[t] = 1; print t }
      }
    }'
}

# spec_areas PATHS
# The spec folders (specs/NNN-name) among the paths, one per line.
spec_areas() {
  printf '%s\n' "$1" | sed -n 's#^\(specs/[0-9][0-9]*-[A-Za-z0-9_-]*\)\(/.*\)\{0,1\}$#\1#p' | sort -u
}

# mocks_files PATHS MOCKS
# MOCKS is the text of a project's scripts/ci/mocks.txt: NAME UI_PATH
# MOCK_PATH... per line. When a named path matches one of a line's paths
# (globs allowed), every path of that line is a file the issue touches.
mocks_files() {
  mf_named=$1
  printf '%s\n' "$2" | tr -d '\r' | while IFS= read -r mf_line; do
    case "$mf_line" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -- $mf_line
    shift
    mf_hit=no
    for mf_p in "$@"; do
      case "$mf_p" in @*) continue ;; esac
      for mf_n in $mf_named; do
        # shellcheck disable=SC2254
        case "$mf_n" in $mf_p) mf_hit=yes ;; esac
        case "$mf_n" in */) case "$mf_p" in "$mf_n"*) mf_hit=yes ;; esac ;; esac
      done
    done
    if [ "$mf_hit" = yes ]; then
      for mf_p in "$@"; do case "$mf_p" in @*) ;; *) printf '%s\n' "$mf_p" ;; esac; done
    fi
  done
}

# past_spec_files LOG
# LOG is git history as "@@ SUBJECT" lines each followed by the files that
# commit changed (git log --name-only --format='@@ %s'). For every commit
# that changed something under a spec folder, print "SPEC<TAB>FILE" for its
# other files, so a new issue on the same spec guesses the files the last
# work on it touched.
past_spec_files() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    function flush(   i, j) {
      for (i = 1; i <= nspec; i++) for (j = 1; j <= nf; j++)
        if (files[j] !~ /^specs\//) print specs[i] "\t" files[j]
      nspec = 0; nf = 0; delete specs; delete files; delete sp
    }
    /^@@/ { flush(); next }
    NF == 0 { next }
    {
      files[++nf] = $0
      if (match($0, /^specs\/[0-9]+-[A-Za-z0-9_-]+/)) {
        s = substr($0, RSTART, RLENGTH)
        if (!(s in sp)) { sp[s] = 1; specs[++nspec] = s }
      }
    }
    END { flush() }' | sort -u
}

# guess_files BODY MOCKS PAST
# The comma-separated, sorted, unique files an issue is guessed to touch:
# the paths its body names, the files of any mocks line they hit, and the
# past files of any spec it names. PAST is past_spec_files' output. Prints
# nothing when the body names no path.
guess_files() {
  gf_paths=$(body_paths "$1")
  [ -n "$gf_paths" ] || return 0
  {
    printf '%s\n' "$gf_paths"
    mocks_files "$gf_paths" "$2"
    for gf_s in $(spec_areas "$gf_paths"); do
      printf '%s/\n' "$gf_s"
      printf '%s\n' "$3" | awk -F'\t' -v s="$gf_s" '$1 == s { print $2 }'
    done
  } | sed '/^$/d' | sort -u | paste -sd, -
}

# plan_units GUESSES RUNNING
# Bundle ready issues by the files they are guessed to touch. Prints:
#   unit  NUMBERS(space)  TITLES(" | ")  WHY  FILES(comma)
#   hold  NUMBER  TITLE  After: TITLE      (touches a running unit's files)
# Issues whose guesses overlap, directly or through a third, are one unit
# (one agent, one pull request); the rest are separate units. An issue that
# overlaps a running unit is held, never started. Units never share a file.
plan_units() {
  { printf '%s\n' "$1" | sed 's/^/G\t/'; printf '%s\n' "$2" | sed 's/^/R\t/'; } | tr -d '\r' | awk -F'\t' '
    function ov(a, b,   na, nb, fa, fb, i, j, x, y) {
      na = split(a, fa, ","); nb = split(b, fb, ",")
      for (i = 1; i <= na; i++) for (j = 1; j <= nb; j++) {
        x = fa[i]; y = fb[j]
        if (x == "" || y == "") continue
        if (x == y) return x
        if (x ~ /\/$/ && index(y, x) == 1) return y
        if (y ~ /\/$/ && index(x, y) == 1) return x
      }
      return ""
    }
    function find(i) { while (par[i] != i) i = par[i]; return i }
    # Plugin and CI work shares one test suite, so it always goes together:
    # any path under plugin/, scripts/ci/ or .github/ also carries "@tooling".
    function tooling(f) { return (("," f) ~ /,(plugin|scripts\/ci|\.github)\//) ? f ",@tooling" : f }
    $1 == "G" && $2 != "" { n++; num[n] = $2; title[n] = $3; files[n] = tooling($4); par[n] = n }
    $1 == "R" && $2 != "" { r++; rtitle[r] = $2; rfiles[r] = tooling($3) }
    END {
      for (i = 1; i <= n; i++) {
        held[i] = ""
        for (k = 1; k <= r; k++) if (ov(files[i], rfiles[k]) != "") { held[i] = rtitle[k]; break }
      }
      for (i = 1; i <= n; i++) if (held[i] == "") for (j = i + 1; j <= n; j++) if (held[j] == "") {
        s = ov(files[i], files[j])
        if (s != "") {
          a = find(i); b = find(j)
          if (a != b) par[b] = a
          if (why[a] == "") why[a] = s
        }
      }
      for (i = 1; i <= n; i++) if (held[i] == "") {
        g = find(i)
        if (!(g in seen)) { seen[g] = 1; order[++u] = g }
        members[g] = members[g] (members[g] == "" ? "" : " ") num[i]
        titles[g] = titles[g] (titles[g] == "" ? "" : " | ") title[i]
        cnt[g]++
        merged[g] = merged[g] (merged[g] == "" ? "" : ",") files[i]
      }
      for (x = 1; x <= u; x++) {
        g = order[x]
        w = ""
        if (cnt[g] > 1) {
          s = why[g]; sub(/\/$/, "", s)
          w = (cnt[g] == 2 ? "both" : "all " cnt[g]) " change " s
          if (s == "@tooling") w = (cnt[g] == 2 ? "both are" : "all " cnt[g] " are") " plugin or CI work, which shares one test suite"
        }
        m = split(merged[g], mf, ","); out = ""
        delete used
        for (q = 1; q <= m; q++) if (mf[q] != "" && mf[q] != "@tooling" && !(mf[q] in used)) { used[mf[q]] = 1; out = out (out == "" ? "" : ",") mf[q] }
        printf "unit\t%s\t%s\t%s\t%s\n", members[g], titles[g], w, out
      }
      for (i = 1; i <= n; i++) if (held[i] != "") printf "hold\t%s\t%s\tAfter: %s\n", num[i], title[i], held[i]
    }'
}

# units_disjoint UNITS
# "yes" when no two unit lines share a file (or a folder and a file in it).
units_disjoint() {
  printf '%s\n' "$1" | awk -F'\t' '
    function ov(a, b) { return a == b || (a ~ /\/$/ && index(b, a) == 1) || (b ~ /\/$/ && index(a, b) == 1) }
    $1 == "unit" { u++; c[u] = split($5, tmp, ","); for (i = 1; i <= c[u]; i++) f[u, i] = tmp[i] }
    END {
      for (a = 1; a <= u; a++) for (b = a + 1; b <= u; b++)
        for (i = 1; i <= c[a]; i++) for (j = 1; j <= c[b]; j++)
          if (f[a, i] != "" && ov(f[a, i], f[b, j])) { print "no"; exit }
      print "yes"
    }'
}

# apply_units ROUND UNITS SLOTS
# Swap the "dispatch N TITLE" goals of a propose_round result for the
# units: one goal per unit, bundles ranked before loose issues (more issues
# first), at most SLOTS of them (the rest deferred, named by their issues),
# and one "hold" line per issue that waits, each saying on what: running
# work, or what hold_reasons (below) found. A bundle reads
# "dispatch 12 14<TAB>Title | Title<TAB>Why together: both change ...".
# When everything is held the stop line says so: work in flight when only
# running work holds it, else what each hold line names.
apply_units() {
  printf '%s\n' "$1" | awk -v slots="${3:-2}" -v units="$2" '
    BEGIN {
      n = split(units, raw, "\n")
      # Bundles first: units carrying more issues rank ahead, in plan order
      # among equals, so a round fills with bundles before loose issues.
      for (i = 1; i <= n; i++) { ul[i] = raw[i]; split(raw[i], f, "\t"); w[i] = (f[1] == "unit") ? split(f[2], tmp, " ") : 0 }
      for (i = 2; i <= n; i++) { v = ul[i]; c = w[i]; j = i - 1; while (j > 0 && w[j] < c) { ul[j + 1] = ul[j]; w[j + 1] = w[j]; j-- } ul[j + 1] = v; w[j + 1] = c }
      for (i = 1; i <= n; i++) {
        split(ul[i], f, "\t")
        if (f[1] == "unit") {
          if (++started <= slots) {
            line = "dispatch " f[2] "\t" f[3]
            if (f[4] != "") line = line "\tWhy together: " f[4]
            goals[++g] = line
          } else { deferred++; piece = "#" f[2]; gsub(/ /, " #", piece); dn = dn (dn == "" ? "" : ", ") piece }
        } else if (f[1] == "hold") { holds[++h] = "hold " f[2] "\t" f[3] "\t" f[4]; if (f[4] !~ /^After: /) reasoned++ }
      }
    }
    /^dispatch / { if (!done) { for (i = 1; i <= g; i++) print goals[i]; done = 1 } next }
    /^defer / { next }
    /^stop:/ {
      if (!done) { for (i = 1; i <= g; i++) print goals[i]; done = 1 }
      for (i = 1; i <= h; i++) print holds[i]
      if (deferred > 0) print "defer " deferred " unit(s): no free runner this round (" dn ")"
      if (g == 0 && other == 0 && h > 0 && reasoned) { print "stop: everything left waits on what its hold line names; publish the round with each hold and its reason"; next }
      if (g == 0 && other == 0 && h > 0) { print "stop: work is in flight; nothing to propose until it lands"; next }
    }
    !/^(stop:|defer )/ { other++ }
    { print }'
}

# hold_reasons FACTS
# FACTS are board-now.sh's lines. A ready issue whose title or body says it
# comes after another open issue ("after #N", "behind #N", "depends on #N",
# "blocked by #N", "waits on #N") is held back, naming what it waits on, in
# the builder's words:
#   hold  NUMBER  TITLE  Waits on your answer on “TITLE” (after: N)
#                        when #N waits on the owner
#   hold  NUMBER  TITLE  Waits for “TITLE” to land (after: N)
#                        when #N is open and not waiting on the owner
# An issue named that is not open (closed, or landed) holds nothing: the
# reason ended with it. Read afresh from the facts on every run; nothing kept.
hold_reasons() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    $1 == "issue" { n++; num[n] = $2; title[n] = $3; labels[n] = "," $4 ","; text[n] = $3 " " $6; open[$2] = n }
    END {
      for (i = 1; i <= n; i++) {
        if (labels[i] !~ /,(state: ?)?ready,/) continue
        s = tolower(text[i])
        if (!match(s, /(after|behind|depends on|blocked by|waits on|waiting on) #[0-9]+/)) continue
        ref = substr(s, RSTART, RLENGTH); sub(/.*#/, "", ref)
        if (!(ref in open) || ref == num[i]) continue
        j = open[ref]
        if (labels[j] ~ /,(state: ?)?waiting-on-owner,/) why = "Waits on your answer on “" title[j] "”"
        else why = "Waits for “" title[j] "” to land"
        printf "hold\t%s\t%s\t%s (after: %s)\n", num[i], title[i], why, ref
      }
    }'
}
