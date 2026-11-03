#!/bin/sh
# One list of rules, and what is built from it. .claude/rules.txt holds the
# rules every project gets with SipNShip (the template sync refreshes it);
# .claude/rules-own.txt holds the project's own, in the same format. From
# them this script builds the table of what enforces each rule in AGENTS.md
# (and in CLAUDE.md when it has one), between the two marker lines:
#
#   <!-- rules: begin ... -->
#   <!-- rules: end -->
#
# A rule whose "applies-when" file is missing is left out. A rule named in
# .claude/rules-off.txt (one "ID YYYY-MM-DD" per line) leaves the table and
# is listed under "Switched off in this project"; a project rule with no
# hook and no check is listed under "Guidance from this project, not
# checked", never in the table. In a project that develops the plugin
# itself (plugin/templates/.claude/rules.txt is there), the template's
# AGENTS.md and CLAUDE.md are built from the plugin's list alone, and the
# hooks' plugin/hooks/COUNTERPARTS.txt from its counterpart lines.
#
# Usage: sh scripts/rules.sh build   rewrite every generated part
#        sh scripts/rules.sh check   fail when one is stale (the rules step
#                                    of the checks CI job)
# A page without the marker lines keeps its table by hand and is skipped.
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(cd "$(dirname "$0")/.." && pwd)
cd "$top" || exit 1

# rules_render ROOT OFF_FILE LIST...: the part between the markers.
rules_render() {
  rr_root=$1; rr_off=$2; shift 2
  rr_offs=""
  [ -n "$rr_off" ] && [ -f "$rr_off" ] && rr_offs=$(tr -d '\r' < "$rr_off")
  OFFS=$rr_offs ROOT=$rr_root awk '
    BEGIN {
      split("January February March April May June July August September October November December", month, " ")
      n = split(ENVIRON["OFFS"], ol, "\n")
      for (i = 1; i <= n; i++) {
        l = ol[i]; sub(/#.*/, "", l); if (split(l, f, /[ \t]+/) < 1 || f[1] == "") continue
        off[f[1]] = f[2] == "" ? "-" : f[2]
      }
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function day(d,   p) {
      if (split(d, p, "-") != 3) return ""
      return month[p[2] + 0] " " (p[3] + 0) ", " p[1]
    }
    function flush(   i, applies, g, nm, tx, k) {
      if (id == "") { reset(); return }
      applies = (when == "" || system("test -e \"" ENVIRON["ROOT"] "/" when "\"") == 0)
      if (applies) {
        g = group
        if (kind != "watch" && (id in off)) {
          k = day(off[id])
          offl[++noff] = "- " words ": off" (k == "" ? "" : " since " k) ". Nothing holds it now; do not count on it."
        } else if (kind != "watch" && hook == "" && check == "") {
          guide[++nguide] = "- " words
        } else {
          for (i = 1; i <= nrow; i++) {
            nm = row[i]; tx = row[i]
            sub(/ \| .*/, "", nm); sub(/^[^|]* \| /, "", tx)
            out[g] = out[g] "| " trim(nm) " | " trim(tx) " |\n"
          }
        }
      }
      reset()
    }
    function reset() { id = ""; kind = "rule"; when = ""; hook = ""; check = ""; words = ""; nrow = 0 }
    FNR == 1 { flush(); group = (FILENAME ~ /rules-own\.txt$/) ? "own" : "sipnship" }
    { sub(/\r$/, "") }
    /^#/ { next }
    /^[ \t]*$/ { flush(); next }
    {
      key = $0; sub(/:.*/, "", key); val = $0; sub(/^[^:]*:[ \t]*/, "", val)
      if (key == "id") id = val
      else if (key == "kind") kind = val
      else if (key == "applies-when") when = val
      else if (key == "hook") hook = val
      else if (key == "check") check = val
      else if (key == "words") words = val
      else if (key == "row") row[++nrow] = val
    }
    END {
      flush()
      head = "| Rule | Enforced by |\n|---|---|\n"
      printf "### From SipNShip\n\n%s%s", head, out["sipnship"]
      if (out["own"] != "") printf "\n### This project'"'"'s own\n\n%s%s", head, out["own"]
      if (nguide) { printf "\n### Guidance from this project, not checked\n\n"; for (i = 1; i <= nguide; i++) print guide[i] }
      if (noff) { printf "\n### Switched off in this project\n\n"; for (i = 1; i <= noff; i++) print offl[i] }
    }
  ' "$@"
}

# rules_splice PAGE PART_FILE: the page with its marked part replaced;
# prints nothing when the page has no markers.
rules_splice() {
  grep -q '^<!-- rules: begin' "$1" && grep -q '^<!-- rules: end -->' "$1" || return 0
  awk -v part="$2" '
    { sub(/\r$/, "") }
    skip && /^<!-- rules: end -->/ { skip = 0; print; next }
    skip { next }
    /^<!-- rules: begin/ { print; print ""; while ((getline l < part) > 0) print l; print ""; skip = 1; next }
    { print }
  ' "$1"
}

# rules_counterparts LIST: the hooks' counterpart file.
rules_counterparts() {
  printf '%s\n' "# Every rule hook and what holds the same rule on the pull request." \
    "# Built by sh scripts/rules.sh build from the counterpart lines of" \
    "# templates/.claude/rules.txt; change those and rebuild, never this file." \
    "# hook | counterpart (path under plugin/templates/, \"session-only\", \"repository-setting\", or \"none yet #N\") | reason" \
    "# A path must exist. \"none yet\" needs the number of the issue that tracks the gap."
  awk '
    { sub(/\r$/, "") }
    /^[ \t]*$/ { hook = ""; next }
    /^hook:/ { hook = $0; sub(/^hook:[ \t]*/, "", hook) }
    /^counterpart:/ { c = $0; sub(/^counterpart:[ \t]*/, "", c); if (hook != "") print hook " | " c }
  ' "$1" | LC_ALL=C sort
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rules.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# One line per page to build: PAGE ROOT OFF_FILE LIST...
targets() {
  [ -f .claude/rules.txt ] || return 0
  own=""; [ -f .claude/rules-own.txt ] && own=.claude/rules-own.txt
  for p in AGENTS.md CLAUDE.md; do echo "$p . .claude/rules-off.txt .claude/rules.txt $own"; done
  if [ -f plugin/templates/.claude/rules.txt ]; then
    for p in AGENTS.md CLAUDE.md; do echo "plugin/templates/$p plugin/templates - plugin/templates/.claude/rules.txt"; done
  fi
}

mode=${1:-}
case "$mode" in build|check) ;; *) echo "Usage: sh scripts/rules.sh build|check" >&2; exit 2 ;; esac
[ -f .claude/rules.txt ] || { echo "No .claude/rules.txt here; nothing to build."; exit 0; }

stale=0; i=0
while read -r page root off lists; do
  [ -f "$page" ] || continue
  i=$((i + 1))
  [ "$off" = - ] && off=""
  # shellcheck disable=SC2086
  rules_render "$root" "$off" $lists > "$tmp/part$i"
  rules_splice "$page" "$tmp/part$i" > "$tmp/page$i"
  [ -s "$tmp/page$i" ] || continue
  if [ "$mode" = build ]; then
    cmp -s "$tmp/page$i" "$page" || { cat "$tmp/page$i" > "$page"; echo "Built the rules table in $page."; }
  elif [ "$(tr -d '\r' < "$page")" != "$(cat "$tmp/page$i")" ]; then
    echo "The rules table in $page is stale: run sh scripts/rules.sh build and commit the result." >&2
    stale=1
  fi
done <<EOF
$(targets)
EOF

cp=plugin/hooks/COUNTERPARTS.txt
if [ -f plugin/templates/.claude/rules.txt ] && [ -f "$cp" ]; then
  rules_counterparts plugin/templates/.claude/rules.txt > "$tmp/cp"
  if [ "$mode" = build ]; then
    cmp -s "$tmp/cp" "$cp" || { cat "$tmp/cp" > "$cp"; echo "Built $cp."; }
  elif [ "$(tr -d '\r' < "$cp")" != "$(cat "$tmp/cp")" ]; then
    echo "$cp is stale: run sh scripts/rules.sh build and commit the result." >&2
    stale=1
  fi
fi

[ "$mode" = check ] && [ "$stale" = 0 ] && echo "The rules tables are current."
exit "$stale"
