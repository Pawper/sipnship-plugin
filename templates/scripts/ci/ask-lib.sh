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
#   confirmation   choices that only say a fix works or does not ("Done", "Not right yet"), no decision in them
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
#   folded     one question stands for several decisions (it names a count of them, or asks to approve them all)
ask_check() { ask_read 1; }

# ask_signature < COMMENTS
# The newest ask's question and choice names, normalized (Markdown stripped,
# lowercased, joined by "|"), so one issue's ask can be compared against
# another's: the same text written once and posted on two issues is caught
# by matching signatures, never by reading the words again (an ask is about
# the one issue it is posted on). "none" when the newest comment with an ask
# has no choices to read (Instructions, a bare question, nothing).
ask_signature() { ask_read 2; }

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
    # A confirmation: a choice that only says a fix shows ("Done", "Yes, it works") or does not ("Not right yet", "Still wrong"). Same words as isConfirm in the core reader.
    function confirm_kind(l,   s) {
      s = tolower(plain(l)); sub(/^[0-9][0-9]?[.)][ \t]+/, "", s)
      sub(/[ \t]*\(.*$/, "", s); sub(/[ \t]+[—-][ \t].*$/, "", s); sub(/[:.!,].*$/, "", s); s = trim(s)
      if (s ~ /^(done|it works|it is working|works|looks good|it looks good|fixed|it is fixed|confirmed|yes|yes it works|yes it does|it is right)$/) return 1
      if (s ~ /^(not right yet|not right|not yet|still wrong|still broken|still not right|not fixed|no|no it does not|it does not work|it is not right|not working)$/) return 2
      return 0
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
    # One question that stands for several decisions: it names a count of choices or decisions, or asks for approval of the lot.
    function folded(q,   t) {
      t = tolower(q)
      return t ~ /(^|[^a-z])(all |both |the )?(two|three|four|five|six|seven|eight|nine|ten|[0-9]+) (drafted |proposed )?(choices|decisions|options|questions)/ || t ~ /(approve|accept|agree to|sign off on) (all|both|every|the whole|the drafted|the proposed)/ || t ~ /(all|both) (the )?(choices|decisions)/
    }
    # Why the words of an ask in the shape would stop a builder, or nothing.
    function wording(L, q, at, n,   k, rec) {
      if (jargon(q)) return "jargon"
      if (folded(q)) return "folded"
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
    # Inline code and fenced code out of a step, to count only its own words.
    function sans_code(s) { s = cut(s, "```", "```"); return cut(s, "`", "`") }
    function wordcount(s,   t) { t = trim(s); gsub(/[^A-Za-z0-9 \t]+/, " ", t); t = trim(t); return t == "" ? 0 : split(t, W, /[ \t]+/) }
    # What an Instructions comment lacks for a builder who is not technical:
    # "noreason" when no plain sentence or two says what it turns on and why
    # (between its first line and its first step), "barecommand" when a step
    # holds a command with no words of its own. Works on the raw text, since
    # the shape reader above drops code.
    function instr_check(raw,   n, k, first, open, step, stext, bare, S) {
      n = split(raw, S, "\n"); first = 0; open = 0; step = 0; stext = ""; bare = 0
      for (k = 1; k <= n; k++) {
        S[k] = trim(S[k]); sub(/\r$/, "", S[k])
        if (S[k] == "") continue
        if (!first) { first = k; continue }
        if (is_choice(S[k])) {
          if (step && stext ~ /`/ && wordcount(sans_code(stext)) < 4) bare = 1
          step = 1; stext = S[k]; continue
        }
        if (!step) { if (substr(S[k], 1, 3) != "```" && substr(S[k], 1, 1) != ">" && wordcount(S[k]) >= 5) open = 1; continue }
        stext = stext "\n" S[k]
      }
      if (step && stext ~ /`/ && wordcount(sans_code(stext)) < 4) bare = 1
      if (!open) return "noreason"
      return bare ? "barecommand" : "instructions"
    }
    function verdict(text,   raw, n, k, m, L, at, before, items, recs, num, q, c1, c2, w, orig) {
      orig = text
      text = cut(text, "<!--", "-->")
      text = cut(text, "```", "```")
      raw = split(text, R, "\n"); n = 0
      for (k = 1; k <= raw; k++) {
        R[k] = trim(R[k])
        if (substr(R[k], 1, 1) == ">") continue
        L[++n] = R[k]
      }
      for (k = 1; k <= n; k++) if (L[k] != "") break
      if (k <= n && tolower(L[k]) ~ /^(\*\*)?[ \t]*instructions[ \t]*(\*\*)?[ \t]*:/) return check == 1 ? instr_check(orig) : (check == 2 ? "none" : "instructions")
      for (at = 1; at <= n; at++) {
        if (!is_choice(L[at])) continue
        num = L[at]; sub(/[.)].*/, "", num)
        if (num != "1") continue
        before = at - 1
        while (before >= 1 && L[before] == "") before--
        if (before < 1 || !asks(L[before])) continue
        items = 0; recs = 0; offs = 0; cyes = 0; cno = 0
        for (k = at; k <= n; k++) {
          if (L[k] == "") continue
          if (!is_choice(L[k])) break
          num = L[k]; sub(/[.)].*/, "", num)
          if (num + 0 != items + 1) break
          items++
          if (recommended(L[k])) recs++
          if (is_putoff(L[k])) offs++
          ck = confirm_kind(L[k]); if (ck == 1) cyes++; else if (ck == 2) cno++
        }
        if (items < 2) continue
        if (check == 2) {
          sg = tolower(trim(plain(L[before])))
          for (k = at; k <= n; k++) { if (L[k] == "") continue; if (!is_choice(L[k])) break; sg = sg "|" cname(L[k]) }
          return sg
        }
        if (items == 2) {
          c1 = cname(L[at]); c2 = ""
          for (k = at + 1; k <= n; k++) if (is_choice(L[k])) { c2 = cname(L[k]); break }
          if ((is_go(c1) && has_action(c1) && is_defer(c2)) || (is_go(c2) && has_action(c2) && is_defer(c1))) return "actiondefer"
        }
        if (cyes > 0 && cno > 0 && cyes + cno == items) return "confirmation"
        if (offs > 0) return "putoff"
        if (recs == 1 && check == 1 && (w = wording(L, L[before], at, n)) != "") return w
        return recs == 1 ? "one" : recs == 0 ? "unrecommended" : "several"
      }
      for (k = n; k >= 1; k--) if (asks(L[k])) return (check == 2 ? "none" : "question")
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
    noreason) printf '%s\n' 'its Instructions open with no plain sentence saying what this turns on for the builder and why the app cannot do it for them. After the first line, add one or two sentences such as "This lets the frost alert reach your phone. Only you can do it, because the key belongs to your account.", then the numbered steps; the last step says how to tell it worked' ;;
    barecommand) printf '%s\n' 'a step of its Instructions holds a command with no words of its own. Say in plain words what the command does before it, such as "2. Start the sensor hub on your rooftop network (this connects the soil sensors): " and then the command, shown whole; never ask a person to make a secret by a command' ;;
    pointer) printf '%s\n' 'the reason after "Recommended" points at where something is written (a section of an issue, a file, a number) instead of saying what the builder gets. Give it as their benefit, such as "Recommended, so the frost alert reaches your phone before tonight."' ;;
    jargon) printf '%s\n' 'its question or the name of a choice carries one of our working words: a script or file name, a label name or a path. Say it as a decision about their project, such as "Should the watering reminders wait for your read?", and keep the working words out of it (a term such as pull request is fine, said plainly)' ;;
    folded) printf '%s
' 'its one question stands for several decisions, so the builder could only approve them all together. Write each decision as its own question with its own choices and exactly one recommendation, and name only that issue'"'"'s own work in it; the review then walks through them one step at a time' ;;
    other) printf '%s\n' 'its question names another issue, so the builder is asked about two pieces of work at once. An ask is about the one issue it is posted on: say only what to look at for this one, and give the other issue its own question, with its own choices and one recommendation' ;;
    twice) printf '%s\n' 'the same question was already posted on another issue in the last day. Each issue gets its own ask, saying what to look at for that issue alone, so the builder never reviews one change twice; write this one for this issue only' ;;
    question) printf '%s\n' 'its ask is a question with no choices. Turn it into choices: keep the question on its own line, then a numbered list of two to four, your best guess first, ending "Recommended." and a short reason why; for an open question, give a draft to say yes to and a last choice such as "I will write my own on the issue."' ;;
    actiondefer) printf '%s\n' 'its ask is a step the owner does outside the app, dressed as a choice between doing it and setting it aside. Write it as Instructions instead: start the comment with the word "Instructions:" and give the steps as a numbered list (what to do, where, any value or command), with no choices and no "Recommended."; if the steps are already done, say so on the issue and move it on instead of waiting' ;;
    confirmation) printf '%s\n' 'its ask only checks that a fix works ("Done", "Not right yet"), which is no decision. Never ask the builder to confirm a fix: it closes when it is built and its tests pass (and, for a screen, when you have seen it on the live page), and the builder reports anew if it is wrong. Close the issue with one comment saying what was built; wait on the builder only for a decision, a design to read, or a step only they can do' ;;
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
