#!/bin/sh
# A drain is not proposed again for pull requests whose last batch went red on
# the same commits and the same main. Pure: every function takes text and
# prints text; tests/run.sh covers each. Sourced by plan.sh.
#
# The queue (scripts/ci/queue/halve.sh, batch_suspect) keeps one line a red
# batch's member in .scratch/queue/red-batches.tsv: the pull request, its head
# commit, main's commit, and why the batch went red (the failing test, else the
# failed jobs). A pull request's own checks do not run the tests, so it stays
# green on its own while the batch is red; without this the plan reads only
# those checks and proposes the same drain again, each costing full runs and
# landing nothing.

# red_batch_goals ROUND ROWS SHAS MAIN
# ROUND is the plan's goal lines; ROWS are red-batches.tsv lines (PR, head
# commit, main's commit, why); SHAS are "NUMBER<TAB>HEAD_SHA" lines for the open
# pull requests; MAIN is main's commit as the project's checkout has it.
# A pull request in a "drain" line, or in a "landing" line that says the queue
# lands it, whose head commit and main are the ones its last batch went red on,
# leaves the line; the line goes when none is left. In its place:
#   fix-main batch<TAB>...   two or more went red alone on the same test on the
#                            same main: main is the likely cause, so the goal
#                            names the test
#   fix-pr N<TAB>...         one went red, with the failing test (or job) named
# A new push or a new main takes the pull request back out of this.
red_batch_goals() {
  printf '%s\n' "$1" | awk -F'\t' -v rows="$2" -v shas="$3" -v main="$4" '
    BEGIN {
      n = split(rows, R, "\n")
      for (i = 1; i <= n; i++) { split(R[i], f, "\t"); if (f[1] != "" && f[3] != "") { rh[f[1]] = f[2]; rm[f[1]] = f[3]; rw[f[1]] = f[4] } }
      n = split(shas, S, "\n")
      for (i = 1; i <= n; i++) { split(S[i], f, "\t"); if (f[1] != "") sha[f[1]] = f[2] }
    }
    function blocked(p) { return main != "" && (p in rh) && (p in sha) && rh[p] == sha[p] && rm[p] == main }
    function reason(p) { return (rw[p] != "" ? rw[p] : "the batch run went red") }
    # prs: the line pull requests; keep: the ones not blocked; the blocked go to the goals.
    function split_prs(prs,   k, m, w) {
      keep = ""; m = split(prs, w, " ")
      for (k = 1; k <= m; k++) {
        if (w[k] == "") continue
        if (blocked(w[k])) { bl[++nb] = w[k] } else keep = keep (keep == "" ? "" : " ") w[k]
      }
    }
    {
      line = $0; prs = ""; tail = ""; kind = ""
      if (line ~ /^drain [0-9 ]+(\t|$)/) {
        kind = "drain"; prs = $1; sub(/^drain /, "", prs); tail = (NF > 1 ? "\t" substr(line, length($1) + 2) : "")
      } else if (line ~ /^landing [0-9 ]+: green; the queue lands them/) {
        kind = "landing"; prs = line; sub(/^landing /, "", prs); sub(/:.*/, "", prs); tail = line; sub(/^landing [0-9 ]+/, "", tail)
      }
      if (kind == "") { out[++no] = line; next }
      nb = 0; delete bl; split_prs(prs)
      if (nb == 0) { out[++no] = line; next }
      if (keep != "") out[++no] = kind " " keep tail
      for (i = 1; i <= nb; i++) { all[++na] = bl[i] }
    }
    END {
      # Two or more with the same cause on the same main: main is the likely cause.
      for (i = 1; i <= na; i++) { w = reason(all[i]); cnt[w]++; who[w] = who[w] (who[w] == "" ? "" : " #") all[i] }
      for (i = 1; i <= na; i++) {
        p = all[i]; w = reason(p)
        if (cnt[w] >= 2) {
          if (!(w in said)) { said[w] = 1; extra[++ne] = "fix-main batch\tthe last batch went red on the same commits and the same main, and #" who[w] " each fail the same way alone: " w ". Main is the likely cause; a drain would only run again for nothing" }
        } else extra[++ne] = "fix-pr " p "\tthe last batch went red with it on this commit and this main: " w ". A drain would only run again for nothing; it is tried again after a new push or once main moves"
      }
      # The goals go before the stop line, with the other goals.
      for (i = 1; i <= no; i++) {
        if (out[i] ~ /^stop:/ && !placed) { for (j = 1; j <= ne; j++) print extra[j]; placed = 1 }
        print out[i]
      }
      if (!placed) for (j = 1; j <= ne; j++) print extra[j]
    }'
}
