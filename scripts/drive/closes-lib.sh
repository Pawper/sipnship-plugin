#!/bin/sh
# A change opened before the closes rule fails the moment the owner approves it
# (#2269). These helpers find the open pull requests the closes check would
# fail, say so in plain words for the builder (whose turn it is: the agent's),
# and give one the issue it closes. Pure: text in, text out; closes-pass.sh runs
# them over REST. Sourced by plan.sh and closes-pass.sh.

# closes_has_line BODY: yes when a line of BODY reads Closes, Fixes or Resolves with an issue number, the check's own rule.
closes_has_line() {
  if printf '%s\n' "$1" | tr -d '\r' | grep -Eiq '^[[:space:]]*(closes|fixes|resolves) +#[0-9]+'; then echo yes; else echo no; fi
}

# closes_missing PULLS: PULLS are "NUMBER<TAB>BRANCH<TAB>CLOSES" lines (CLOSES the issue numbers the body closes, comma
# separated, as the plan reads them). The numbers the closes check would fail, one a line: no Closes line, and not the
# queue's own batch, which carries none.
closes_missing() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '$1 != "" && $3 == "" && $2 !~ /^(batch|merge-queue)/ { print $1 }'
}

# closes_part_of BODY: the first issue number a Part of, Refs or Spec for line names, or nothing.
closes_part_of() {
  closes_part_of_all "$1" | head -n 1
}

# closes_part_of_all BODY: every issue number a Part of, Refs or Spec for line names, in the body's own order, one a
# line. A change naming several (a part of more than one still-open build) needs more than the first to find which one
# is still open (closes_pick_open_build).
closes_part_of_all() {
  printf '%s\n' "$1" | tr -d '\r' | tr 'A-Z' 'a-z' | sed -n 's/^[[:space:]]*\(part of\|refs\?\|spec for\|relates to\):\{0,1\} *#\([0-9][0-9]*\).*/\2/p'
}

# closes_pick_open_build CANDIDATES STATES: CANDIDATES are issue numbers, one a line, in the body's own order
# (closes_part_of_all); STATES are "NUMBER<TAB>STATE" lines, the state ("open" or "closed") of each. The first
# candidate whose state is "open", so a change part of several builds names the one still going, not one already
# done; with none open, the first candidate (nothing is more right to name); nothing when there are no candidates.
closes_pick_open_build() {
  { printf '%s\n' "$1" | tr -d '\r'; echo '---'; printf '%s\n' "${2:-}" | tr -d '\r'; } | awk '
    /^---$/ { sep = 1; next }
    !sep { if ($0 != "") cand[++nc] = $0; next }
    { st[$1] = $2 }
    END {
      for (i = 1; i <= nc; i++) { if (first == "") first = cand[i]; if (st[cand[i]] == "open") { print cand[i]; exit } }
      if (first != "") print first
    }'
}

# closes_spec_only FILES: yes when every file (one a line) is a spec or a mock (under specs/ or design/), so the change is
# the spec and mocks of a build and its own small issue can close it; no otherwise, and no for an empty list.
closes_spec_only() {
  printf '%s\n' "$1" | tr -d '\r' | awk 'NF { n++; if ($0 !~ /^(specs|design)\//) bad = 1 } END { print (n > 0 && !bad) ? "yes" : "no" }'
}

# closes_spec_title TITLE: the title of the small issue for a spec-and-mocks change, in plain words.
closes_spec_title() { printf 'The spec and mocks of %s\n' "$1"; }

# closes_add_line BODY ISSUE BUILD [BUILD_TITLE]: BODY with its Part of line made plain and a Closes line added. The build's
# issue, when there is one, stays open and is named in words.
closes_add_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v n="$2" -v b="${3:-}" -v t="${4:-}" '
    BEGIN { done = 0 }
    { print }
    END {
      print ""; print "Closes #" n
      if (b != "") print "The build itself, " (t != "" ? "\"" t "\" " : "") "(#" b "), stays open and is its own change."
    }'
}

# closes_builder_words TITLE: what the builder reads on the Work tab for an approved change a check stopped for want of an
# issue to close, with whose turn it is (the agent's), so it never looks approved and stuck.
closes_builder_words() {
  printf '“%s” is approved, but a check stopped it: it names no issue it closes. Your agent is on it, and nothing is needed from you.\n' "$1"
}

# closes_notes FACTS PR_LIST: one plain line for each open pull request the closes check would fail, so it is seen before
# the owner approves it. PR_LIST are the plan's pull lines (unit separator between number, branch, labels, hold, closes).
closes_notes() {
  cn_us=$(printf '\037')
  cn_rows=$(printf '%s\n' "$2" | tr -d '\r' | awk -F"$cn_us" 'NF { printf "%s\t%s\t%s\n", $1, $2, $5 }')
  for cn_n in $(closes_missing "$cn_rows"); do
    cn_title=$(printf '%s\n' "$1" | awk -F'\t' -v n="$cn_n" '$1 == "pr" && $2 == n { print $3; exit }')
    printf 'closes: pull request #%s %swould fail the closes check: it names no issue it closes. Your agent gives it one; nothing is needed from you.\n' "$cn_n" "${cn_title:+“$cn_title” }"
  done
}
