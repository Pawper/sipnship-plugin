#!/bin/sh
# The kept label, for the machines kept for the batch and main (scripts/ci/RUNNERS.md): a batch's jobs ask
# for it by name so they never land on an ordinary machine (#2856). Pure helpers; loaded by
# scripts/ci/batch-lib.sh, with the pr label's own helpers in rules-requests.sh.

# The kept machines also carry this label, so a batch's jobs can ask for them by name
# (the runs-on expression in ci.yml) instead of taking any machine, ordinary ones included (#2856).
KEPT_LABEL=kept

# kept_label_plan RUNNERS: the label changes that leave the kept label on exactly
# the runners that lack the pr label, one "add|remove<TAB>id<TAB>name" a line,
# nothing when it is already right. RUNNERS is the same lines runner_label_plan
# reads, as they stand once its changes are made. An offline runner is judged
# like the others, so a role that moves with its runner never needs a second
# pass. With every runner carrying pr (fewer than two online, or the queue
# cannot manage runners) no runner carries kept, and a batch's jobs then ask
# for any machine, as ci.yml says while CI_KEEP_RUNNER is not on.
kept_label_plan() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v pr="$KEEP_LABEL" -v kept="$KEPT_LABEL" '
    NF >= 3 && $1 != "" { l = "," $4 ","; has_pr = index(l, "," pr ",") > 0; has_kept = index(l, "," kept ",") > 0
      if (!has_pr && !has_kept) printf "add\t%s\t%s\n", $1, $2
      else if (has_pr && has_kept) printf "remove\t%s\t%s\n", $1, $2 }'
}

# plan_applied RUNNERS PLAN: RUNNERS as they stand once runner_label_plan's PLAN
# has been made, so the kept label is planned from the labels the drain just set.
plan_applied() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v plan="$2" -v pr="$KEEP_LABEL" '
    BEGIN { n = split(plan, pl, "\n"); for (i = 1; i <= n; i++) { split(pl[i], f, "\t"); if (f[2] != "") act[f[2]] = f[1] } }
    NF >= 3 && $1 != "" { l = $4
      if (($1 in act) && act[$1] == "add") l = (l == "" ? pr : l "," pr)
      else if (($1 in act) && act[$1] == "remove") { t = "," l ","; sub("," pr ",", ",", t); gsub(/^,|,$/, "", t); l = t }
      printf "%s\t%s\t%s\t%s\n", $1, $2, $3, l }'
}
