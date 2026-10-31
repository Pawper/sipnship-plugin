#!/bin/sh
# Pure helpers for serial mode, conflicts and holds. Loaded by
# scripts/ci/batch-lib.sh.

# nearest_root FILE ROOTS
# ROOTS is one folder per line, each holding a package.json or tsconfig.json
# ("." for the repository root). Print the deepest root that contains FILE,
# so a test in web/src/a.test.ts runs from web/ when web/package.json exists,
# and from "." otherwise. Print nothing when no root contains it.
nearest_root() {
  nr_f=$(printf '%s' "$1" | tr '\\' '/')
  printf '%s\n' "$2" | tr -d '\r' | tr '\\' '/' | awk -v f="$nr_f" '
    { r = $0; sub(/\/$/, "", r); if (r == "" ) next
      if (r == ".") { if (length(best) == 0 && !seen) { best = "."; seen = 1 }; next }
      if (substr(f, 1, length(r) + 1) == r "/" && length(r) > length(best)) { best = r; seen = 1 } }
    END { if (seen) print best }'
}

# serial_refusal READY BECAUSE
# READY is the other open pull requests that are green and do not conflict
# with main, space separated; BECAUSE is the reason given with --because.
# Print why a serial merge is refused, or nothing when it may go: alone is
# fine when nothing else is ready, and a named reason always is. One agent
# hard-coded --serial into a landing script and copied it for every pull
# request; five that were ready together each landed alone, with a full CI
# run and a deploy apiece.
serial_refusal() {
  [ -z "$(printf '%s' "$2" | tr -d ' ')" ] || return 0
  [ -n "$(printf '%s' "$1" | tr -d ' ')" ] || return 0
  sr_n=$(printf '%s\n' $1 | wc -l | tr -d ' ')
  sr_list=$(printf '#%s ' $1 | sed 's/ $//')
  echo "$sr_n other green pull request(s) are ready to land with it ($sr_list); merge them together with --drain (or --batch), or give the reason this one must land alone: --serial N --because migration|conflict|must-land-alone|\"why\""
}

# serial_title TITLE NUMBER REASON
# The squash commit title of a serial merge, carrying its reason, so the
# nightly audit can read main's history: "Fix the chime (#79) [serial: alone]".
serial_title() {
  printf '%s (#%s) [serial: %s]\n' "$1" "$2" "${3:-alone}"
}

# serial_bursts LINES [WINDOW_SECONDS] [MAX]
# LINES is main's recent first-parent history, "epoch<TAB>subject", one per
# line. Print one line when more than MAX (default 2) serial merges landed
# within WINDOW (default an hour): how many, their reasons, and what to do.
# Nothing otherwise.
serial_bursts() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v win="${2:-3600}" -v max="${3:-2}" '
    $2 ~ /\[serial: [^]]*\]/ {
      r = $2; sub(/.*\[serial: /, "", r); sub(/\].*/, "", r)
      t[++n] = $1 + 0; why[n] = r
    }
    END {
      # times arrive newest first from git log; sort ascending
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (t[j] < t[i]) { x = t[i]; t[i] = t[j]; t[j] = x; y = why[i]; why[i] = why[j]; why[j] = y }
      best = 0
      for (i = 1; i <= n; i++) { k = 0; for (j = i; j <= n && t[j] - t[i] <= win; j++) k++; if (k > best) { best = k; bi = i } }
      if (best <= max) exit
      rs = ""; for (j = bi; j < bi + best; j++) rs = rs (rs == "" ? "" : ", ") why[j]
      printf "Main took %d serial merges within an hour (reasons: %s). Pull requests that are ready together should land as one batch: sh scripts/ci/merge-queue.sh --drain.\n", best, rs
    }'
}

# conflict_line FILES
# FILES is the conflicting paths from git merge-tree, one per line. Print
# the one line a serial run says for a pull request that conflicts with
# main, instead of "updated" round after round.
conflict_line() {
  cl=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n 5 | tr '\n' ' ' | sed 's/ $//')
  cl_gen=""; [ "$2" = generated ] && cl_gen="; generated only: a rebuild on the batch would resolve this"
  if [ -n "$cl" ]; then echo "conflicts with main in $cl$cl_gen; resolve it on the branch, then queue it again"
  else echo "conflicts with main$cl_gen; resolve it on the branch, then queue it again"; fi
}

# batch_members BODY
# The member pull requests a batch pull request's body lists, one number
# per line, from its "- #N title. Closes #N" lines.
batch_members() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^- #\([0-9][0-9]*\) .*/\1/p'
}

# drop_members LIST MEMBERS
# LIST is the drain's rows, "NUMBER<TAB>...". Print LIST without the rows
# whose number is in MEMBERS (space or line separated). A member of an
# open batch belongs to that batch: the drain once merged two members on
# their own while their batch ran CI, then sent the batch round again.
drop_members() {
  printf '%s\n' "$1" | awk -F'\t' -v m=" $(printf '%s' "$2" | tr '\n' ' ') " 'NF && index(m, " " $1 " ") == 0'
}

# queue_eta QUEUED BUSY RUNNERS [AVG_MINUTES]
# One line on a run that waits on machines rather than tests: how many
# jobs are queued, how many runners are busy, and a rough time to clear
# the queue (each runner runs one job at a time; AVG_MINUTES per job,
# default 4). Nothing when no job is queued.
queue_eta() {
  [ "${1:-0}" -gt 0 ] 2>/dev/null || return 0
  qe_r=${3:-0}; [ "$qe_r" -gt 0 ] 2>/dev/null || qe_r=0
  if [ "$qe_r" -eq 0 ]; then printf '%s job(s) queued and no runner online.\n' "$1"; return 0; fi
  qe_eta=$(( ($1 + qe_r - 1) / qe_r * ${4:-4} ))
  printf '%s job(s) queued, %s of %s runner(s) busy; about %s minute(s) at one job per runner. Waiting on machines, not on a failure.\n' "$1" "${2:-0}" "$qe_r" "$qe_eta"
}

# anchored_group ORDER PAIRS
# ORDER is the batch's pull requests, earliest first, space separated.
# PAIRS is one conflicting pair per line, "A B". Print the batch: the
# first pull request always, then the largest set of the others that
# conflicts with nothing in it, earliest first on a tie. Merging in order
# and dropping each conflict kept {251, 252} and left 253 and 254 out when
# 253 and 254 conflicted only with 252; this keeps {251, 253, 254}.
# Exhaustive up to 16 pull requests, in order after that.
anchored_group() {
  printf '%s\n' "$2" | awk -v order="$1" '
    NF == 2 { c[$1 " " $2] = 1; c[$2 " " $1] = 1 }
    END {
      n = split(order, p, " ")
      if (n == 0) exit
      if (n > 17) {
        k = 0
        for (i = 1; i <= n; i++) { ok = 1; for (j = 1; j <= k; j++) if ((p[i] " " g[j]) in c) ok = 0; if (ok) g[++k] = p[i] }
        for (j = 1; j <= k; j++) print g[j]
        exit
      }
      best = -1; bestkey = ""
      m = n - 1; total = 2 ^ m
      for (mask = 0; mask < total; mask++) {
        k = 1; s[1] = p[1]; ok = 1; key = ""
        for (b = 0; b < m && ok; b++) {
          if (int(mask / 2 ^ b) % 2 == 0) continue
          x = p[b + 2]
          for (j = 1; j <= k; j++) if ((x " " s[j]) in c) { ok = 0; break }
          s[++k] = x
        }
        if (!ok) continue
        # earlier first on a tie: the key reads the chosen positions in order
        for (b = 0; b < m; b++) key = key (int(mask / 2 ^ b) % 2 ? "1" : "0")
        if (k > best || (k == best && key > bestkey)) { best = k; bestkey = key; for (j = 1; j <= k; j++) out[j] = s[j] }
      }
      for (j = 1; j <= best; j++) print out[j]
    }'
}

# conflict_notice FILES WITH
# The comment the queue leaves on a pull request it could not merge for a
# conflict: which files, with what, and what to do. WITH is "main" or a
# pull request number. The owning agent finds it on its next session.
conflict_notice() {
  cn_files=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n 10 | sed 's/^/- `/; s/$/`/')
  if [ "$2" = main ]; then cn_with="main"; else cn_with="#$2, which goes into this batch first"; fi
  printf 'The merge queue could not take this pull request: it conflicts with %s' "$cn_with"
  if [ -n "$cn_files" ]; then printf ' in:\n\n%s\n\n' "$cn_files"; else printf '.\n\n'; fi
  if [ "$3" = generated ]; then printf 'Every file here is generated build output (scripts/ci/generated-paths.txt): a rebuild on the batch would resolve this, and the queue does that itself when the list names a rebuild: command.\n\n'; fi
  printf 'To resolve it: in this branch'"'"'s worktree, merge main in (`git fetch origin && git merge origin/main`), fix the files, run their tests, and push. Never rebase or force-push. The queue takes it again once it is green. It is labeled state:blocked until then.\n'
}

# held_reason LABELS BODY
# LABELS is a pull request's label names, one per line. Print why it is
# held when it carries the label "queue:hold" or "hold", or a line
# "Queue: hold" in its body; nothing otherwise. A held pull request is
# green but not to be merged yet: the drain landed one under a batch in
# progress, and batched two that were meant to land one at a time.
held_reason() {
  if printf '%s\n' "$1" | tr -d '\r' | grep -qixE 'queue:hold|hold'; then echo "held by its label"; return 0; fi
  if printf '%s\n' "$2" | tr -d '\r' | grep -qiE '^[[:space:]]*queue:[[:space:]]*hold'; then echo 'held by its "Queue: hold" line'; fi
  return 0
}
