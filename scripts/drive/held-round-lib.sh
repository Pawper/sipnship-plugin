#!/bin/sh
# The holds the drive already published stay out of the next plan's slots.
# When the drive, on reading issues in full, held them in its proposed round
# (the part left sits in another area, they wait on a change not yet landed),
# the plan does not hand them the next round's slots again: the slots go to the
# next ready unit, and the defer line says so. Pure helpers, text in and text
# out; tests/run.sh covers each. Sourced by plan.sh after round-state-lib.sh.

# published_holds COMMENTS FACTS [OPEN_PRS]
# COMMENTS are the drive issue's comments ("at<TAB>login<TAB>body" lines); the
# latest sipnship-proposal marker, proposed or started, carries the round's
# held list. FACTS are board-now's lines, OPEN_PRS the open pull requests'
# numbers one per line. One "hold<TAB>NUMBER<TAB>TITLE<TAB>WHY" line (the shape
# of bundle-lib's hold_reasons) for each of its held issues that is still Ready
# and whose reason is still true: the issues it waits on are still open and its
# pull request, when it names one, is still open. A hold the plan works out
# fresh each round (part of the issue landed) is never carried, and any hold
# whose issue changed after the proposal was published is read afresh (#2048). A deferral for want of a
# runner is no hold and takes nothing here.
published_holds() {
  printf '%s\n' "$1" | tr -d '\r' | grep -F 'sipnship-proposal {"status":' | tail -n 1 | awk -v facts="$2" -v open="${3:-}" '
    BEGIN {
      n = split(facts, fl, "\n")
      for (i = 1; i <= n; i++) { split(fl[i], f, "\t"); if (f[1] == "issue") { isopen[f[2]] = 1; title[f[2]] = f[3]; upd[f[2]] = f[5]; if (("," f[4] ",") ~ /,(state: ?)?ready,/) ready[f[2]] = 1 } }
      n = split(open, ol, "\n"); for (i = 1; i <= n; i++) if (ol[i] != "") op[ol[i]] = 1
    }
    {
      s = $0; at = $0; sub(/	.*/, "", at)
      i = index(s, "\"held\":["); if (!i) exit
      s = substr(s, i + 8)
      if (j = index(s, "\"apart\":[")) s = substr(s, 1, j - 1)
      if (j = index(s, "\"waits\":\"")) s = substr(s, 1, j - 1)
      if (j = index(s, "\"sized\":\"")) s = substr(s, 1, j - 1)
      n = split(s, parts, /\{"issues":\[/)
      for (k = 2; k <= n; k++) {
        p = parts[k]; iss = p; sub(/\].*/, "", iss); gsub(/,/, " ", iss)
        why = ""; if (match(p, /"why":"([^"\\]|\\.)*"/)) { why = substr(p, RSTART + 7, RLENGTH - 8); gsub(/\\"/, "\"", why) }
        if (why ~ /[Nn]o free runner|free runners? this round/) continue
        if (why ~ /^Part of it landed/) continue  # the plan reads this one fresh every round from the issue itself (left-lib.sh), so it is never carried
        pr = ""; if (match(p, /"pr":[0-9]+/)) pr = substr(p, RSTART + 5, RLENGTH - 5)
        if (pr != "" && open != "" && !(pr in op)) continue
        wait = ""; if (match(p, /"waitsOn":\[[0-9,]*\]/)) { wait = substr(p, RSTART + 11, RLENGTH - 12); gsub(/,/, " ", wait) }
        if (wait != "") { m = split(wait, w, " "); live = 0; for (x = 1; x <= m; x++) if (w[x] in isopen) live = 1; if (!live) continue }
        m = split(iss, is, " ")
        for (x = 1; x <= m; x++) if ((is[x] in ready) && !(is[x] in seen) && !(upd[is[x]] ~ /^[0-9][0-9][0-9][0-9]-/ && upd[is[x]] > at)) {  # an issue touched since the proposal is read afresh
          seen[is[x]] = 1
          printf "hold\t%s\t%s\tHeld in the last proposed round%s; it takes no slot until that changes\n", is[x], title[is[x]], (why != "" ? ": " why : "")
        }
      }
    }'
}

# published_held_areas COMMENTS
# One "ISSUES<TAB>WAITSON<TAB>AREAS" line (each comma separated) for every held
# entry of the latest published round that names an area: the areas
# publish-round.sh checks a new unit against, since a held entry in the same
# area as a unit it does not wait on is refused. Nothing when none names one.
published_held_areas() {
  printf '%s\n' "$1" | tr -d '\r' | grep -F 'sipnship-proposal {"status":' | tail -n 1 | awk '
    {
      s = $0; i = index(s, "\"held\":["); if (!i) exit
      s = substr(s, i + 8)
      if (j = index(s, "\"apart\":[")) s = substr(s, 1, j - 1)
      if (j = index(s, "\"waits\":\"")) s = substr(s, 1, j - 1)
      if (j = index(s, "\"sized\":\"")) s = substr(s, 1, j - 1)
      n = split(s, parts, /\{"issues":\[/)
      for (k = 2; k <= n; k++) {
        p = parts[k]; iss = p; sub(/\].*/, "", iss); gsub(/ /, "", iss)
        wait = ""; if (match(p, /"waitsOn":\[[0-9, ]*\]/)) { wait = substr(p, RSTART + 11, RLENGTH - 12); gsub(/ /, "", wait) }
        ar = ""; if (match(p, /"areas":\[[^]]*\]/)) { ar = substr(p, RSTART + 9, RLENGTH - 10); gsub(/[" ]/, "", ar) }
        if (ar != "") printf "%s\t%s\t%s\n", iss, wait, ar
      }
    }'
}

# defer_note ROUND COUNT
# ROUND is the plan's lines, COUNT how many issues the last round held that
# took no slot. The plan's "defer N unit(s): ... (#5 #6)" line says so, so a
# builder sees why a small round is small; the line is otherwise unchanged and
# still ends in its issue list.
defer_note() {
  case "${2:-0}" in ""|0|*[!0-9]*) printf '%s\n' "$1"; return 0 ;; esac
  printf '%s\n' "$1" | awk -v c="$2" '
    /^defer [0-9]+ unit\(s\):/ && match($0, / \(#[^)]*\)$/) {
      print substr($0, 1, RSTART - 1) "; the " c " issue" (c == 1 ? "" : "s") " held since the last round take" (c == 1 ? "s" : "") " no slot" substr($0, RSTART); next
    }
    { print }'
}
