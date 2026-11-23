#!/bin/sh
# Why a ready issue is held, and the stall line when all are (specs/023-drive-on-work, #2055). Text in, text out.

# hold_reasons FACTS [HELDONLY]
# FACTS are board-now.sh's lines. A ready issue whose title or body says it
# comes after another open issue ("after #N", "behind #N", "depends on #N",
# "blocked by #N", "waits on #N") is held back, naming what it waits on, in
# the builder's words. A chain (A after B after C) is followed to its first
# cause, so the hold names the one thing that frees the whole chain:
#   hold  NUMBER  TITLE  Waits on your answer on "TITLE" (after: N)
#                        when the cause waits on the owner
#   hold  NUMBER  TITLE  Waits on your read of "TITLE" (after: N)
#                        when the cause is in HELDONLY (issue numbers whose
#                        only pull request is held for the owner's read)
#   hold  NUMBER  TITLE  Waits for "TITLE" to land (after: N)
#                        when the cause is open with an agent at work
# An issue named that is not open (closed, or landed) holds nothing: the
# reason ended with it. Read afresh from the facts on every run; nothing kept.
# A title's own quotation marks and every other character pass through whole: the quotes this
# function wraps a title in are plain ASCII ("), never curly ones, because a curly mark written
# directly into this awk program's own source is a command-line argument when sh execs awk, and on
# this project's Windows runners that argument is re-encoded through a narrow code page before awk
# ever sees it, turning each multi-byte mark into the Unicode replacement character (#2397). A
# title's own characters, which arrive as piped data rather than as part of the awk program text,
# are never exec'd as an argument anywhere in this path and so are not at risk the same way.
hold_reasons() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v heldonly=" $(printf '%s' "${2:-}" | tr '\n' ' ') " '
    function refof(k,   s, r) {
      s = tolower(text[k])
      if (!match(s, /(after|behind|depends on|blocked by|waits on|waiting on) #[0-9]+/)) return ""
      r = substr(s, RSTART, RLENGTH); sub(/.*#/, "", r)
      return r
    }
    $1 == "issue" { n++; num[n] = $2; title[n] = $3; labels[n] = "," $4 ","; text[n] = $3 " " $6; open[$2] = n }
    END {
      for (i = 1; i <= n; i++) {
        if (labels[i] !~ /,(state: ?)?ready,/) continue
        ref = refof(i)
        if (ref == "" || !(ref in open) || ref == num[i]) continue
        j = open[ref]; first = ref
        # Follow the chain while the cause itself waits behind another open issue and no owner answer or read stops it.
        for (d = 0; d < 10; d++) {
          if (labels[j] ~ /,(state: ?)?waiting-on-owner,/ || index(heldonly, " " num[j] " ")) break
          r2 = refof(j)
          if (r2 == "" || !(r2 in open) || open[r2] == i || r2 == num[j]) break
          j = open[r2]
        }
        if (labels[j] ~ /,(state: ?)?waiting-on-owner,/) why = "Waits on your answer on \"" title[j] "\""
        else if (index(heldonly, " " num[j] " ")) why = "Waits on your read of \"" title[j] "\""
        else why = "Waits for \"" title[j] "\" to land"
        printf "hold\t%s\t%s\t%s (after: %s)\n", num[i], title[i], why, first
      }
    }'
}

# stall_note ROUND [RUNNERS_ONLINE]
# ROUND is the plan's result after apply_units. When no unit is dispatched
# and every ready issue is held, the round says so as a stall and names the
# one or two owner actions that free the most issues:
#   stall: every ready issue is held; answering "T"
#   frees K issues, reading "U" frees J
# When no owner action frees any of them, the round says that instead, in plain words: how many
# issues are held and how many wait on what is left of them being written down (#2047), so a round
# that holds everything is never a quiet one. A RUNNERS_ONLINE of 0 says nothing here: no runner is
# a different cause, told elsewhere.
stall_note() {
  [ "${2:-}" != 0 ] || return 0
  printf '%s\n' "$1" | awk -F'\t' '
    /^dispatch / { go = 1 }
    /^hold / {
      h++
      if ($3 ~ /^(After: |Waits for ")/) {
        w = $3; sub(/ \(after: [0-9 ,#]+\)$/, "", w); sub(/ \[(shares: [^]]*|area: [^]]*|tooling)\]$/, "", w); sub(/^(After: |Waits for ")/, "", w); sub(/" to land.*$/, "", w); wc[w]++
        if (wc[w] > wtop) { wtop = wc[w]; wname = w }
      }
      if ($3 ~ /held for your read/) rd++  # an issue its held change carries waits on a read by the builder (#2267)
      if (match($3, /^Waits on your (answer|read) on "[^"]*"/)) {
        c = substr($3, RSTART, RLENGTH); verb = (c ~ /^Waits on your read/) ? "reading" : "answering"
        sub(/^Waits on your (answer|read) on /, "", c); key = verb " " c; cnt[key]++
        if (!(key in seen)) { seen[key] = 1; ord[++k] = key }
      }
    }
    END {
      if (go || h == 0) exit
      if (k == 0) {
        if (rd > 0) printf "stall: every ready issue is held (%d), and %d of them wait on your read of a held change", h, rd
        else printf "stall: every ready issue is held (%d), and nothing in it waits on you", h
        if (wtop * 2 > h) printf "; %d of them wait for \"%s\" to land, the reason most share", wtop, wname
        printf "\n"
        exit
      }
      for (a = 1; a <= k; a++) for (b = a + 1; b <= k; b++) if (cnt[ord[b]] > cnt[ord[a]]) { t = ord[a]; ord[a] = ord[b]; ord[b] = t }
      out = ""
      for (a = 1; a <= k && a <= 2; a++) out = out (a > 1 ? ", " : "") ord[a] " frees " cnt[ord[a]] " issue" (cnt[ord[a]] == 1 ? "" : "s")
      printf "stall: every ready issue is held; %s\n", out
    }'
}
