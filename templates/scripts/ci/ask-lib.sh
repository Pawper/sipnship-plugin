#!/bin/sh
# An ask with choices recommends exactly one. What counts as an ask, its
# choices and "recommended" is the plain convention the dashboard reads onto
# an issue's Needs you card:
#   - the question is one line ending in a question mark, right before the
#     choices; without numbered choices, the last such line is the question;
#   - the choices are a numbered list starting at 1, right after it;
#   - a choice is recommended when its line says "Recommended" (and not
#     "not recommended");
#   - quoted lines, code and HTML comments are never read.
# The dashboard's reader keeps the same definition in TypeScript; both are
# tested against the same fixtures, one comment per case, in the plugin's
# tests/fixtures/ask/, so the two never drift.
# Sourced by the state-label hook and the nightly audit. Pure.

# The line that parts one comment from the next on ask_verdict's input.
ASK_NEXT="--- next comment ---"

# ask_verdict < COMMENTS
# COMMENTS are one or more comment bodies, newest first, parted by a line
# that is exactly $ASK_NEXT. Prints what the newest comment that carries an
# ask says about its recommendation, one word:
#   none           no comment carries an ask
#   question       a question with no choices
#   one            choices, exactly one recommended
#   unrecommended  choices, none recommended
#   several        choices, more than one recommended
ask_verdict() {
  awk -v next_line="$ASK_NEXT" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    # Inline Markdown down to its words, enough to see a line end in "?".
    function plain(s,   out) {
      while (match(s, /!?\[[^]]*\]\([^)]*\)/)) {
        out = substr(s, RSTART, RLENGTH); sub(/^!?\[/, "", out); sub(/\]\([^)]*\)$/, "", out)
        s = substr(s, 1, RSTART - 1) out substr(s, RSTART + RLENGTH)
      }
      gsub(/`|\*\*|__|\*/, "", s)
      gsub(/(^|[^A-Za-z0-9])_/, " ", s); gsub(/_([^A-Za-z0-9]|$)/, " ", s)
      sub(/^#+[ \t]+/, "", s)
      return trim(s)
    }
    function is_choice(l) { return l ~ /^[0-9][0-9]?[.)][ \t]+[^ \t]/ }
    function asks(l) { return l != "" && !is_choice(l) && plain(l) ~ /\?$/ }
    function recommended(l,   s) {
      s = tolower(plain(l))
      gsub(/(^|[^a-z])not[ \t]+recommended/, " ", s)
      return s ~ /(^|[^a-z])recommended([^a-z]|$)/
    }
    # Cut every piece from OPEN to the next CLOSE, or to the end.
    function cut(s, from, to,   a, b, out) {
      out = ""
      while ((a = index(s, from)) > 0) {
        out = out substr(s, 1, a - 1)
        s = substr(s, a + length(from))
        b = index(s, to)
        if (b == 0) { s = ""; break }
        s = substr(s, b + length(to))
      }
      return out s
    }
    function verdict(text,   raw, n, k, m, L, at, before, items, recs, num, q) {
      text = cut(text, "<!--", "-->")
      text = cut(text, "```", "```")
      raw = split(text, R, "\n"); n = 0
      for (k = 1; k <= raw; k++) {
        R[k] = trim(R[k])
        if (substr(R[k], 1, 1) == ">") continue
        L[++n] = R[k]
      }
      for (at = 1; at <= n; at++) {
        if (!is_choice(L[at])) continue
        num = L[at]; sub(/[.)].*/, "", num)
        if (num != "1") continue
        before = at - 1
        while (before >= 1 && L[before] == "") before--
        if (before < 1 || !asks(L[before])) continue
        items = 0; recs = 0
        for (k = at; k <= n; k++) {
          if (L[k] == "") continue
          if (!is_choice(L[k])) break
          num = L[k]; sub(/[.)].*/, "", num)
          if (num + 0 != items + 1) break
          items++
          if (recommended(L[k])) recs++
        }
        if (items < 2) continue
        return recs == 1 ? "one" : recs == 0 ? "unrecommended" : "several"
      }
      for (k = n; k >= 1; k--) if (asks(L[k])) return "question"
      return "none"
    }
    {
      sub(/\r$/, "")
      if ($0 == next_line) {
        v = verdict(body); body = ""; got = 0
        if (v != "none") { print v; done = 1; exit }
        next
      }
      body = got ? body "\n" $0 : $0; got = 1
    }
    END {
      if (done) exit
      v = got ? verdict(body) : "none"
      print v
    }'
}

# ask_fix VERDICT
# What to fix, in a sentence, for a verdict that breaks the rule; nothing for
# one that keeps it.
ask_fix() {
  case "$1" in
    unrecommended) printf '%s\n' 'its ask gives choices and none is recommended. End the one you would pick with "Recommended." and a short reason why, in the same comment' ;;
    several) printf '%s\n' 'its ask gives choices and more than one says "Recommended". Keep the word on the one you would pick, with a short reason why, and take it off the others' ;;
  esac
}
