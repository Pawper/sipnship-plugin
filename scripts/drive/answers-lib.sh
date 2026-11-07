#!/bin/sh
# The builder's answers to what the drive asked, as the drive reads them. The
# dashboard writes one comment on the issue (or on its pull request, when the
# question was asked there), in two lines: plain words for anyone reading,
# then the fixed form the asker reads, the only door:
#
#   Maya answered on the dashboard: Yes, let it land.
#   Builder answer: #214 choice 1 by maya
#
# The second line may name the ask it answers and the decision inside it
# ("ask <comment id> decision <n>"), and a changed answer ends it with
# "changes <comment id>", in that order. A person
# may write the same line by hand on GitHub, and it counts the same. The
# form's words are the dashboard's own; a test holds the two in step. Pure;
# sourced by answers.sh and the plugin's tests.

# answer_line BODY
# The answer a comment carries, as "ISSUE CHOICE LOGIN CHANGES" (CHANGES is
# 0 when none), or nothing. A whole line in the fixed form, not quoted and not
# inside a code block; the first such line wins. BODY may hold real line ends
# or the two characters "\n" that a tab-separated read leaves.
answer_line() {
  printf '%s\n' "$1" | awk '
    { gsub(/\r/, ""); gsub(/\\n/, "\n"); text = text (NR > 1 ? "\n" : "") $0 }
    END {
      # A code block is cut out whole, as the dashboard cuts it, to the end when it never closes.
      while ((a = index(text, "```")) > 0) {
        rest = substr(text, a + 3); b = index(rest, "```")
        text = substr(text, 1, a - 1) (b ? substr(rest, b + 3) : "")
      }
      n = split(text, L, "\n")
      for (i = 1; i <= n; i++) {
        raw = L[i]; line = raw; gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (substr(line, 1, 1) == ">") continue
        if (line !~ /^Builder answer: #[0-9]+ choice [0-9][0-9]? by [A-Za-z0-9][A-Za-z0-9-]*( ask [0-9]+)?( decision [0-9]{1,2})?( changes [0-9]+)?$/) continue
        nw = split(line, w, " ")
        if (length(w[7]) > 39) continue
        issue = w[3]; sub(/^#/, "", issue)
        chg = 0
        for (t = 8; t < nw; t += 2) if (w[t] == "changes") chg = w[t + 1] + 0
        print issue + 0, w[5] + 0, w[7], chg
        exit
      }
    }'
}

# owed_answers COMMENTS OPEN
# COMMENTS are comments on the repository's issues and pull requests, one
# "id<TAB>at<TAB>login<TAB>on<TAB>body" a line, where "on" is the number of
# the issue or pull request it was written on; any order. OPEN is the open
# issues the drive left waiting on the builder or that an answer moved to
# Ready, one number per line. Prints the answer in force on each, oldest
# first, while it is still owed:
#   answer #214 choice 1 by maya (comment 9001)
# with ", changes 8990" before the bracket's end for a changed answer. The
# newest answer (by time, then id) counts. An answer counts when the App wrote
# it or the person it names did; another person's line in that name is not
# theirs. It is no longer owed once someone other than the person who
# answered comments after it on the issue, or where the answer was written,
# as the drive does when it carries on: the same rule the dashboard uses to
# stop an answer changing.
owed_answers() {
  oa_t=$(printf '\t')
  oa_rows=$(printf '%s\n' "$1" | tr -d '\r' | while IFS="$oa_t" read -r oa_id oa_at oa_by oa_on oa_body; do
    [ -n "$oa_id" ] || continue
    oa_line=$(answer_line "$oa_body")
    printf '%s\t%s\t%s\t%s\t%s\n' "$oa_id" "$oa_at" "$oa_by" "$oa_on" "${oa_line:--}"
  done)
  printf '%s\n' "$oa_rows" | awk -F'\t' -v open="$(printf '%s ' $2)" '
    BEGIN { n = split(open, o, " "); for (i = 1; i <= n; i++) if (o[i] != "") want[o[i]] = 1 }
    NF < 5 { next }
    { id[NR] = $1; at[NR] = $2; by[NR] = tolower($3); on[NR] = $4; ans[NR] = $5; rows = NR }
    END {
      for (r = 1; r <= rows; r++) {
        if (ans[r] == "-") continue
        split(ans[r], a, " ")
        if (!(a[1] in want)) continue
        if (by[r] != tolower(a[3]) && by[r] !~ /\[bot\]$/) continue
        k = a[1]
        if (!(k in best) || at[r] > at[best[k]] || (at[r] == at[best[k]] && id[r] + 0 > id[best[k]] + 0)) best[k] = r
      }
      for (k in best) {
        b = best[k]; split(ans[b], a, " "); spent = 0
        for (r = 1; r <= rows; r++) {
          if (r == b || ans[r] != "-" || at[r] <= at[b]) continue
          if (on[r] != k && on[r] != on[b]) continue
          if (by[r] != tolower(a[3])) { spent = 1; break }
        }
        if (!spent) out[++c] = at[b] "\t" sprintf("answer #%s choice %s by %s (comment %s%s)", k, a[2], a[3], id[b], a[4] ? ", changes " a[4] : "")
      }
      # Oldest first, by time: a small insertion sort, since awk has no sort of its own everywhere.
      for (i = 2; i <= c; i++) { v = out[i]; j = i - 1; while (j >= 1 && out[j] > v) { out[j + 1] = out[j]; j-- } out[j + 1] = v }
      for (i = 1; i <= c; i++) { sub(/^[^\t]*\t/, "", out[i]); print out[i] }
    }'
}

# unseen_answers OWED SEEN
# The owed answers whose comment is not among SEEN (comment ids, one a line),
# so the drive reads each answer once.
unseen_answers() {
  printf '%s\n' "$1" | awk -v seen="$(printf '%s ' $2)" '
    BEGIN { n = split(seen, s, " "); for (i = 1; i <= n; i++) if (s[i] != "") had[s[i]] = 1 }
    /^answer #/ { c = $0; sub(/.*\(comment /, "", c); sub(/[,)].*/, "", c); if (!(c in had)) print }'
}

# answer_ids LINES
# The comment ids of answer lines, one a line.
answer_ids() {
  printf '%s\n' "$1" | sed -n 's/^answer #.*(comment \([0-9][0-9]*\).*/\1/p'
}
