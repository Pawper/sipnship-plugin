#!/bin/sh
# An ask gives choices and recommends exactly one. What counts as an ask, its
# choices and "recommended" is the plain convention the dashboard reads onto
# an issue's Needs you card:
#   - the question is one line ending in a question mark, right before the
#     choices; without numbered choices, the last such line is the question;
#   - the choices are a numbered list starting at 1, right after it;
#   - a choice is recommended when its line says "Recommended" (and not
#     "not recommended");
#   - quoted lines, code and HTML comments are never read;
#   - a comment whose first line starts "Instructions:" is steps the owner
#     does outside the app, not a decision: it needs no choices and no
#     "Recommended.";
#   - two choices that are an action and a deferral ("Lift it and add the
#     secret" / "Set it aside") are an owner action dressed as a decision:
#     they are to be written as Instructions.
#   - a choice that reads the thing, or decides later ("Read it first", "Read it
#     and let it land", "Decide later"), decides nothing: reading is never a
#     choice, so an ask about something to read names it and offers the outcomes
#     that follow the read (approve it, ask for changes).
# The dashboard's reader keeps the same definition in TypeScript; both are
# tested against the same fixtures, one comment per case, in the plugin's
# tests/fixtures/ask/, so the two never drift.
# ask_check reads the same ask and, when its shape keeps the rule, holds its
# words to what a builder who is not technical can answer (fixtures in
# tests/fixtures/ask-plain/): every choice has a short name the card shows
# whole, the recommendation's reason is a benefit and not a pointer to where
# something is written, and the question and the choices' names carry no
# script, file, label or path. Whether the words read plainly beyond that is a
# reader's judgement, not this file's.
# Sourced by the state-label hook, the nightly audit, the drive's plan and the
# queue. Pure.

# The line that parts one comment from the next on ask_verdict's input.
ASK_NEXT="--- next comment ---"

# ask_verdict < COMMENTS
# COMMENTS are one or more comment bodies, newest first, parted by a line
# that is exactly $ASK_NEXT. Prints what the newest comment that carries an
# ask says about its recommendation, one word:
#   none           no comment carries an ask
#   instructions   steps for the owner, marked "Instructions:" (no choice)
#   actiondefer    two choices that are an action and a deferral
#   putoff         a choice that is only to read it, or to decide later
#   question       a question with no choices
#   one            choices, exactly one recommended
#   unrecommended  choices, none recommended
#   several        choices, more than one recommended
ask_verdict() { ask_read 0; }

# ask_check < COMMENTS
# ask_verdict's word, except that an ask in the shape ("one") whose words a
# builder could not answer as written says why instead:
#   longname   a choice's short name is past the card's 80 characters, so it is cut
#   pointer    the recommendation's reason points at an issue's section, a file or a number
#   jargon     the question or a choice's name carries a script, file, label or path
ask_check() { ask_read 1; }

# The one reader behind both; CHECK is 1 for ask_check.
ask_read() {
  awk -v next_line="$ASK_NEXT" -v check="$1" '
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
    # A choice line down to its short name: the words before a colon or a
    # full stop, lowercased.
    function cname(l,   s) {
      s = tolower(plain(l)); sub(/^[0-9][0-9]?[.)][ \t]+/, "", s)
      sub(/[:.].*$/, "", s); sub(/[ 	]+$/, "", s)
      return trim(s)
    }
    function is_go(s) { return s ~ /^(lift it|do it|go ahead|yes)([^a-z]|$)/ }
    function has_action(s) { return s ~ /(^|[^a-z])(add|install|run|create|set up|press|open|configure|connect|download|enable)([^a-z]|$)/ }
    function is_defer(s) { return s ~ /^(set it aside|not now|defer|leave it|skip|keep it held|park it)([^a-z]|$)/ }
    # A choice that only reads the thing or puts the decision off. Same words as isPutOff in the core reader.
    function is_putoff(l,   s) {
      s = tolower(plain(l)); sub(/^[0-9][0-9]?[.)][ \t]+/, "", s)
      sub(/[ \t]*\(.*$/, "", s); sub(/[ \t]+[—-][ \t].*$/, "", s); sub(/[.:!\t ]+$/, "", s)
      sub(/[:.].*$/, "", s); sub(/[ 	]+$/, "", s)
      return s ~ /^(read([ ,].*)?|let me read([ ,].*)?|look at it( first| later)?|look it over|have a look|decide later|decide it later|i will decide later|later|not yet|think about it|let me think( about it)?)$/
    }
    # A choice split as the card splits it (choiceOf in the core reader): the
    # word "Recommended" taken out, then the words before a colon within 60
    # characters, else the first sentence. Sets NAME and REASON.
    function split_choice(l,   s, low, p, before, after, body, c) {
      s = plain(l); sub(/^[0-9][0-9]?[.)][ \t]+/, "", s)
      low = tolower(s); gsub(/not[ \t]+recommended/, "not xecommended", low)
      body = s; REASON = ""
      if (match(low, /(^|[^a-z])recommended([^a-z]|$)/)) {
        p = RSTART + (substr(low, RSTART, 1) == "r" ? 0 : 1)
        before = substr(s, 1, p - 1); sub(/[ \t(-]+$/, "", before)
        after = substr(s, p + 11); sub(/^[ \t]*\)?[.,;-]*/, "", after)
        if (before == "") { body = after; sub(/^[ \t)\]:,;-]+/, "", body) }
        else if (after ~ /^[ \t]*:/) { sub(/^[ \t]+/, "", after); body = before after }
        else { body = before; REASON = after; sub(/^[ \t)\]:,;-]+/, "", REASON) }
      }
      c = index(body, ": ")
      if (c > 2 && c <= 61) NAME = substr(body, 1, c - 1)
      else { NAME = body; if (match(body, /[.!?][ \t]/)) NAME = substr(body, 1, RSTART); sub(/\.$/, "", NAME) }
      NAME = trim(NAME)
    }
    # Our working words: a script or file name, a label name, a path.
    function jargon(s,   t) {
      t = tolower(plain(s)); gsub(/(and|either|yes)\/(or|no)/, " ", t); gsub(/https?:\/\/[^ ]*/, " ", t)
      return t ~ /[a-z0-9_-]\.(sh|ts|tsx|js|mjs|cjs|json|ya?ml|md|txt|toml)([^a-z0-9]|$)/ || t ~ /(^|[^a-z0-9])[a-z]+:[a-z][a-z-]*/ || t ~ /(^|[^a-z-])ci-red([^a-z-]|$)/ || t ~ /[a-z0-9_.-]\/[a-z0-9_.-]/
    }
    # A reason that says where something is written instead of what it gives.
    function pointer(s,   t) {
      t = tolower(s)
      return t ~ /#[0-9]+/ || t ~ /(done when|what to change|section|issue.s own|the issue (says|asks)|the spec (says|asks))/ || jargon(s)
    }
    # Why the words of an ask in the shape would stop a builder, or nothing.
    function wording(L, q, at, n,   k, rec) {
      if (jargon(q)) return "jargon"
      for (k = at; k <= n; k++) {
        if (L[k] == "") continue
        if (!is_choice(L[k])) break
        split_choice(L[k])
        if (length(NAME) > 80) return "longname"
        if (jargon(NAME)) return "jargon"
        if (recommended(L[k]) && REASON != "" && pointer(REASON)) rec = "pointer"
      }
      return rec
    }
    function verdict(text,   raw, n, k, m, L, at, before, items, recs, num, q, c1, c2, w) {
      text = cut(text, "<!--", "-->")
      text = cut(text, "```", "```")
      raw = split(text, R, "\n"); n = 0
      for (k = 1; k <= raw; k++) {
        R[k] = trim(R[k])
        if (substr(R[k], 1, 1) == ">") continue
        L[++n] = R[k]
      }
      for (k = 1; k <= n; k++) if (L[k] != "") break
      if (k <= n && tolower(L[k]) ~ /^(\*\*)?[ \t]*instructions[ \t]*(\*\*)?[ \t]*:/) return "instructions"
      for (at = 1; at <= n; at++) {
        if (!is_choice(L[at])) continue
        num = L[at]; sub(/[.)].*/, "", num)
        if (num != "1") continue
        before = at - 1
        while (before >= 1 && L[before] == "") before--
        if (before < 1 || !asks(L[before])) continue
        items = 0; recs = 0; offs = 0
        for (k = at; k <= n; k++) {
          if (L[k] == "") continue
          if (!is_choice(L[k])) break
          num = L[k]; sub(/[.)].*/, "", num)
          if (num + 0 != items + 1) break
          items++
          if (recommended(L[k])) recs++
          if (is_putoff(L[k])) offs++
        }
        if (items < 2) continue
        if (items == 2) {
          c1 = cname(L[at]); c2 = ""
          for (k = at + 1; k <= n; k++) if (is_choice(L[k])) { c2 = cname(L[k]); break }
          if ((is_go(c1) && has_action(c1) && is_defer(c2)) || (is_go(c2) && has_action(c2) && is_defer(c1))) return "actiondefer"
        }
        if (offs > 0) return "putoff"
        if (recs == 1 && check == 1 && (w = wording(L, L[before], at, n)) != "") return w
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
# What to fix, in plain words, for a verdict that breaks the rule; nothing for
# one that keeps it ("one" and "instructions"). A question with no choices breaks it too: every ask the
# builder sees gives choices and a suggested one, so an open question is
# turned into choices, the best guess first. No ask at all ("none") breaks it
# where an issue is set to wait on the builder: they would have nothing to answer.
ask_fix() {
  case "$1" in
    none) printf '%s\n' 'no ask or Instructions comment was left on it in the last ten minutes, so the builder would find nothing to answer. First leave one comment: what happened, in a plain sentence or two; the question, as a decision about their project; two to four choices, each a short name, a colon and what it means for them, one ending "Recommended." with how it helps them. For a step only they can do, start the comment with "Instructions:" and number the steps. An ask left earlier is not read as the reason for this wait, so post it again' ;;
    longname) printf '%s\n' 'a choice has no short name, so the card cuts it off mid-sentence. Start every choice with a name of a few words (80 characters at most), then a colon, then what it means for them, such as "2. Ask for changes: say what to change, and your agent makes it before anything lands."' ;;
    pointer) printf '%s\n' 'the reason after "Recommended" points at where something is written (a section of an issue, a file, a number) instead of saying what the builder gets. Give it as their benefit, such as "Recommended, so the frost alert reaches your phone before tonight."' ;;
    jargon) printf '%s\n' 'its question or the name of a choice carries one of our working words: a script or file name, a label name or a path. Say it as a decision about their project, such as "Should the watering reminders wait for your read?", and keep the working words out of it (a term such as pull request is fine, said plainly)' ;;
    question) printf '%s\n' 'its ask is a question with no choices. Turn it into choices: keep the question on its own line, then a numbered list of two to four, your best guess first, ending "Recommended." and a short reason why; for an open question, give a draft to say yes to and a last choice such as "I will write my own on the issue."' ;;
    actiondefer) printf '%s\n' 'its ask is a step the owner does outside the app, dressed as a choice between doing it and setting it aside. Write it as Instructions instead: start the comment with the word "Instructions:" and give the steps as a numbered list (what to do, where, any value or command), with no choices and no "Recommended."; if the steps are already done, say so on the issue and move it on instead of waiting' ;;
    putoff) printf '%s\n' 'one of its choices is only to read the thing, or to decide later. Reading is never a choice: the builder is there to read it. Name the file or files to read in the comment (a link that opens it), and make every choice an outcome that follows the read: "Approve it as written", "Ask for changes" (the builder says what), and any real alternative such as "Split it: the spec waits for your read, the rest lands now"' ;;
    unrecommended) printf '%s\n' 'its ask gives choices and none is recommended. End the one you would pick with "Recommended." and a short reason why, in the same comment' ;;
    several) printf '%s\n' 'its ask gives choices and more than one says "Recommended". Keep the word on the one you would pick, with a short reason why, and take it off the others' ;;
  esac
}

# The hidden line that marks a script's ask about one held pull request, so the
# same ask is never left twice. HTML comments are never read as the ask.
held_ask_mark() { printf '<!-- sipnship-held-ask #%s -->' "$1"; }

# held_ask NUMBER TITLE URL
# The ask a script leaves on the issue a held pull request closes: what is held,
# named by its title as a link, then the decision that follows reading it.
held_ask() {
  held_ask_mark "$1"; printf '\n'
  printf 'A change your agent finished is held for your read before it goes into your project: [%s](%s). It is a pull request (#%s): the proposed change, with what it does and why. The work that comes after it waits until you say.\n\n' "$2" "$3" "$1"
  printf 'Should this change go into your project?\n\n'
  printf '1. Approve it: it goes in with the next landing. Recommended, so the work that comes after it can start.\n'
  printf '2. Ask for changes: say what to change, and your agent makes it before anything goes in.\n'
}
