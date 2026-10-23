#!/bin/sh
# Pure helpers for CI: classify changed paths, decide whether a merge needs a
# re-run, and read the State field out of an issue body.

# classify_paths PATHS RULES
# PATHS is one path per line. RULES is the text of classes.txt. Print the
# matching classes, sorted, space separated. A path that matches no rule is
# class "other". A line starting with "!" is a directive, not a class
# (see rerun_free_classes), and is skipped here.
classify_paths() {
  cp_rules=$2
  set -f
  printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | while IFS= read -r cp_p; do
    [ -n "$cp_p" ] || continue
    cp_cls=
    while IFS= read -r cp_line; do
      cp_line=${cp_line%%#*}
      set -- $cp_line
      [ $# -ge 2 ] || continue
      case "$1" in '!'*) continue ;; esac
      cp_c=$1
      shift
      for cp_pat in "$@"; do
        case "$cp_p" in $cp_pat) cp_cls=$cp_c; break ;; esac
      done
      if [ -n "$cp_cls" ]; then break; fi
    done <<EOF
$cp_rules
EOF
    printf '%s\n' "${cp_cls:-other}"
  done | sort -u | tr '\n' ' ' | sed 's/ $//'
  set +f
}

# rerun_decision NEEDS_RERUN MAIN_STATE [POLICY]
# NEEDS_RERUN is needs_rerun's answer for a green pull request that merges
# cleanly onto main; MAIN_STATE is main's newest CI run on main's current
# commit: green, red, pending (still running, or main has a newer commit
# with no run yet) or unknown. Print "merge" or "update".
#
# A green pull request that merges cleanly onto a green main merges
# without a second run, even when main moved in its classes: the full run
# on main is the gate, and it opens the red-main issue if the two together
# fail. A re-run is kept only when main is red or its newest commit is not
# yet known to be green. One batch went through three full CI cycles for
# the same code before this. POLICY "classes" restores the old rule:
# re-run whenever main moved in the pull request's classes.
rerun_decision() {
  [ "$1" = yes ] || { echo merge; return 0; }
  [ "${3:-green-main}" = classes ] && { echo update; return 0; }
  if [ "$2" = green ]; then echo merge; else echo update; fi
}

# state_labels_json CURRENT NEW
# CURRENT is an issue's labels, one per line; NEW is its state label. Print
# the JSON body that sets the labels to CURRENT without any other state
# label, plus NEW: {"labels":["bug","state:ready"]}. One REST call sets it,
# where gh issue edit goes through GraphQL and fails with the board under
# GitHub's secondary limit.
state_labels_json() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v new="$2" '
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    NF && tolower($0) !~ /^state:/ && !seen[$0]++ { out = out (out == "" ? "" : ",") q($0) }
    END { if (new != "") out = out (out == "" ? "" : ",") q(new); print "{\"labels\":[" out "]}" }'
}

# checks_queued_only STATUSES
# STATUSES is one check run status per line (queued, in_progress,
# completed). Print "yes" when at least one is queued and none is running:
# the run waits for a machine, not for its tests. "no" otherwise.
checks_queued_only() {
  printf '%s\n' "$1" | tr -d '\r' | tr 'A-Z' 'a-z' | awk '
    /queued|waiting|pending|requested/ { q = 1 }
    /in_progress/ { r = 1 }
    END { print (q && !r) ? "yes" : "no" }'
}

# runner_stall QUEUED_ONLY ONLINE
# QUEUED_ONLY is checks_queued_only for the pull requests the drain waits
# on; ONLINE is how many self-hosted runners are online, or "unknown" when
# they could not be read. Print "stop" when waiting is pointless (every
# check queued, no runner online), "unknown" when it might be, nothing when
# the wait is real. Three drains once waited twelve minutes each on runners
# that had gone home for the night.
runner_stall() {
  [ "$1" = yes ] || return 0
  case "$2" in
    0) echo stop ;;
    ''|unknown) echo unknown ;;
  esac
}

# board_refusal TEXT
# Print "yes" when gh's output means GitHub refused a board call for a
# rate limit: the gh project commands print "unknown owner type" when
# their GraphQL query is refused, which says nothing about the real
# cause, and gh api says "rate limit". Print "no" otherwise.
board_refusal() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    *"unknown owner type"*|*"rate limit"*|*"secondary"*|*"abuse"*) echo yes ;;
    *) echo no ;;
  esac
}

# rerun_free_classes RULES
# Print the classes named on a "!rerun-free" line of classes.txt: the ones
# whose moves on main can never make a green pull request red (specs,
# docs, the status page), so the queue ignores them when deciding on a
# re-run. Print nothing when there is no such line.
rerun_free_classes() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    { sub(/#.*/, "") }
    $1 == "!rerun-free" { $1 = ""; sub(/^[ \t]+/, ""); print; exit }'
}

# needs_rerun PR_CLASSES MAIN_CLASSES [FREE_CLASSES]
# Print "yes" when a green PR must run CI again before merging because main
# moved in a class the PR touches, in the ci class, or in an unclassified
# file. Print "no" when main moved only outside the PR's classes, only in
# FREE_CLASSES (the rerun-free ones), or has not moved at all since the
# merge base: then nothing the PR touches, classified or not, needs a
# second run. Ten pull requests that each touch a spec would otherwise
# invalidate one another on every merge and go round CI one at a time.
needs_rerun() {
  nr_main=""
  for nr_m in $2; do
    case " $3 " in *" $nr_m "*) continue ;; esac
    nr_main="$nr_main $nr_m"
  done
  [ -n "$(printf '%s' "$nr_main" | tr -d ' \t')" ] || { echo no; return 0; }
  for nr_a in $1; do
    for nr_b in $nr_main; do
      if [ "$nr_a" = "$nr_b" ]; then echo yes; return 0; fi
    done
  done
  case " $1 $nr_main " in *" other "*) echo yes; return 0 ;; esac
  case " $nr_main " in *" ci "*) echo yes; return 0 ;; esac
  echo no
}

# The state label's form. The plugin's labels.sh makes "state:in-progress"
# (compact); a project that named its own "state: in progress" (spaced)
# keeps them, and every script here writes and reads the project's form.
# One project's state-label workflow set a second set of labels beside its
# own. The form is read once from the repository's labels
# (project_label_form) and passed down, or held in LABEL_FORM.

# state_slug LABEL
# The state a label names, as a slug: "state:in-progress", "state: in
# progress" and "State: In Progress" all give "in-progress". Nothing for a
# label that is not a state label.
state_slug() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    tolower($0) ~ /^[ \t]*state:/ {
      v = tolower($0); sub(/^[ \t]*state:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v); gsub(/[ \t]+/, "-", v)
      if (v != "") print v
    }'
}

# state_label_form LABELS
# LABELS is the repository's labels, one per line. Print "spaced" when the
# project names its state labels with a space after the colon, else
# "compact".
state_label_form() {
  if printf '%s\n' "$1" | tr -d '\r' | grep -qiE '^state: '; then echo spaced; else echo compact; fi
}

# state_label SLUG [FORM]
# The label for a state slug in the given form (default LABEL_FORM, else
# compact): "in-progress" -> "state:in-progress" or "state: in progress".
state_label() {
  case "${2:-${LABEL_FORM:-compact}}" in
    spaced) printf 'state: %s\n' "$(printf '%s' "$1" | tr '-' ' ')" ;;
    *) printf 'state:%s\n' "$1" ;;
  esac
}

# state_labels_all [FORM]
# The eight state labels in the form, one per line.
state_labels_all() {
  for sla in ready in-progress waiting-on-owner waiting-on-service parked dated after-launch blocked; do state_label "$sla" "$1"; done
}

# project_label_form
# The repository's form, from its labels, one REST call; "compact" when
# the call fails or gh is absent. Callers read it once into LABEL_FORM.
project_label_form() {
  if command -v gh >/dev/null 2>&1; then
    state_label_form "$(gh api "repos/{owner}/{repo}/labels?per_page=100" --jq '.[].name' 2>/dev/null)"
  else echo compact; fi
}

# state_label_from_body BODY [FORM]
# Print the state label for the "### State" field in an issue body written
# by the task template, for example "state:waiting-on-owner", in the
# project's form. Print nothing when the field is missing or empty.
state_label_from_body() {
  slb_v=$(printf '%s\n' "$1" | tr -d '\r' | awk '
    found && $0 !~ /^[ \t]*$/ {
      v = tolower($0)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v == "_no response_") exit
      gsub(/[ \t]+/, "-", v)
      print v
      exit
    }
    /^### State[ \t]*$/ { found = 1 }
  ')
  [ -z "$slb_v" ] || state_label "$slb_v" "$2"
}

# spec_check_reason PATHS [TEXT] [ROOTS]
# PATHS is one changed path per line; TEXT is the pull request's title and
# body; ROOTS is the source roots, one folder per line (default "src/";
# scripts/ci/spec-roots.txt lists a project's own, such as android/). A source change must belong to a spec: either TEXT names one
# ("Spec: specs/<feature>" or any "specs/<feature>/" mention) or the change
# touches a feature folder under specs/. The spec is written before
# building, so naming it is the normal case; touching it is for a change
# that changes the design. A touch requirement alone made every pull
# request append a line to spec.md to pass, which is the shared-page
# append the rules forbid. Print "missing" when the change touches src/
# and does neither (the constitution does not count). Print "many N" when
# it touches N feature folders and N is more than one, a warning. Print
# nothing when the change is fine or touches no source.
spec_check_reason() {
  sc_src=0
  sc_roots=$(printf '%s\n' "${3:-src/}" | tr -d '\r' | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; s#/*$#/#' | paste -sd'|' -)
  sc_folders=$(printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | awk -v roots="${sc_roots:-src/}" '
    BEGIN { nr = split(roots, r, "|") }
    { for (i = 1; i <= nr; i++) if (index($0, r[i]) == 1) src = 1 }
    /^specs\/[^\/]+\// { f = $0; sub(/^specs\//, "", f); sub(/\/.*/, "", f); folders[f] = 1 }
    END {
      n = 0
      for (f in folders) n++
      print src, n
    }')
  sc_src=${sc_folders%% *}
  sc_n=${sc_folders#* }
  [ "$sc_src" = 1 ] || return 0
  sc_named=$(printf '%s\n' "$2" | tr -d '\r' | awk '
    tolower($0) ~ /(^|[^a-z])spec:[ \t]*[a-z0-9_.\/-]/ { print "named"; exit }
    /specs\/[A-Za-z0-9_.-]+\// { print "named"; exit }')
  if [ "$sc_n" -eq 0 ] && [ "$sc_named" = named ]; then
    return 0
  elif [ "$sc_n" -eq 0 ]; then
    echo missing
  elif [ "$sc_n" -gt 1 ]; then
    echo "many $sc_n"
  fi
}

# setup_manual SETUP_PATTERNS
# Print the path of the manual named by a "manual PATH" line in the
# patterns, or SETUP.md when there is none.
setup_manual() {
  sm=$(printf '%s\n' "$1" | tr -d '\r' | awk '$1 == "manual" && NF >= 2 { print $2; exit }')
  printf '%s\n' "${sm:-SETUP.md}"
}

# setup_check_reason PATHS SETUP_PATTERNS
# PATHS is one changed path per line. SETUP_PATTERNS is one shell glob per
# line naming the files whose change is a setup step, plus an optional
# "manual PATH" line naming the manual when it is not SETUP.md. Print the
# first changed path that matches a pattern when the manual did not change
# with it. Print nothing when the manual changed too or nothing setup-shaped
# changed.
setup_check_reason() {
  set -f
  sc_hit=
  sc_setup=0
  sc_manual=$(setup_manual "$2")
  sc_paths=$(printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/')
  case "
$sc_paths
" in *"
$sc_manual
"*) sc_setup=1 ;; esac
  [ "$sc_setup" = 0 ] || { set +f; return 0; }
  sc_hit=$(printf '%s\n' "$sc_paths" | while IFS= read -r sc_p; do
    [ -n "$sc_p" ] || continue
    printf '%s\n' "$2" | tr -d '\r' | while IFS= read -r sc_pat; do
      case "$sc_pat" in ''|'#'*|manual\ *|manual\	*) continue ;; esac
      case "$sc_p" in $sc_pat) printf '%s\n' "$sc_p"; break ;; esac
    done
  done | head -n 1)
  set +f
  [ -n "$sc_hit" ] && printf '%s\n' "$sc_hit"
  return 0
}

# shared_mix_reason PATHS SHARED_PATTERNS
# PATHS is one changed path per line. SHARED_PATTERNS is one shell glob per
# line naming shared code. Print the first shared path when the change
# touches shared code and also touches something that is not shared. Print
# nothing when the change is only shared code, touches none, or the list
# is empty.
shared_mix_reason() {
  set -f
  sm_shared=""; sm_other=0
  sm_out=$(printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | while IFS= read -r sm_p; do
    [ -n "$sm_p" ] || continue
    sm_hit=no
    printf '%s\n' "$2" | tr -d '\r' > /dev/null
    for sm_pat in $(printf '%s\n' "$2" | tr -d '\r' | sed 's/#.*//' | sed '/^[ \t]*$/d'); do
      case "$sm_p" in $sm_pat) sm_hit=yes; break ;; esac
    done
    printf '%s\t%s\n' "$sm_hit" "$sm_p"
  done)
  set +f
  sm_shared=$(printf '%s\n' "$sm_out" | awk -F'\t' '$1 == "yes" { print $2; exit }')
  sm_other=$(printf '%s\n' "$sm_out" | awk -F'\t' '$1 == "no" { n++ } END { print n + 0 }')
  if [ -n "$sm_shared" ] && [ "$sm_other" -gt 0 ]; then printf '%s\n' "$sm_shared"; fi
  return 0
}

# has_crlf TEXT
# Print "yes" when TEXT contains a carriage return, nothing otherwise.
has_crlf() {
  if printf '%s' "$1" | tr -d -c '\r' | grep -q .; then echo yes; fi
}

# state_name_from_label LABEL
# "state:waiting-on-owner" or "state: waiting on owner" -> "Waiting on
# owner". Prints nothing for a label that is not a state label.
state_name_from_label() {
  snl_s=$(state_slug "$1")
  [ -n "$snl_s" ] || return 0
  printf '%s\n' "$snl_s" | tr '-' ' ' | awk '{ $1 = toupper(substr($1, 1, 1)) substr($1, 2); print }'
}

# label_from_state_name NAME [FORM]
# "Waiting on owner" -> "state:waiting-on-owner", in the project's form.
label_from_state_name() {
  state_label "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ' ' '-')" "$2"
}

# state_label_in LABELS
# LABELS is a comma separated list. Print the first state label, in either
# form, or nothing.
state_label_in() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | awk 'tolower($0) ~ /^state:/ { print; exit }'
}

# status_for STATE_NAME CLOSED
# The board's built-in Status that mirrors a State: Done for a closed issue,
# In Progress for "In progress", Todo for everything else.
status_for() {
  if [ "$2" = "true" ] || [ "$2" = "closed" ] || [ "$2" = "CLOSED" ]; then echo "Done"; return 0; fi
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    "in progress") echo "In Progress" ;;
    *) echo "Todo" ;;
  esac
}

# workflow_breaks RUNS CHANGES
# RUNS is one workflow run per line: "path<TAB>conclusion<TAB>created_epoch"
# (any order). CHANGES is one line per workflow the project changed:
# "path<TAB>changed_epoch<TAB>date<TAB>title", its last change on main.
# Print one line for each workflow whose last run before its change passed
# and whose every run since has failed: "audit.yml has failed every run (3)
# since it was changed on 2026-10-15 (Sync templates to plugin 0.22.1)".
# A template sync once broke a project's nightly audit and nothing said so
# for two days. Nothing for a workflow with no run before the change, no
# run after it, a pass since, or a run still going.
workflow_breaks() {
  { printf '%s\n' "$2" | tr -d '\r' | awk -F'\t' 'NF >= 3 { print "C\t" $0 }'
    printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' 'NF >= 3 { print "R\t" $0 }'; } | awk -F'\t' '
    $1 == "C" { at[$2] = $3 + 0; day[$2] = $4; title[$2] = $5; next }
    $1 == "R" && ($2 in at) {
      p = $2; conc = $3; t = $4 + 0
      if (t > at[p]) {
        after[p]++
        if (conc == "success" || conc == "skipped" || conc == "neutral") okafter[p] = 1
        else if (conc != "failure" && conc != "startup_failure" && conc != "timed_out") okafter[p] = 1
      } else if (t > before_t[p]) { before_t[p] = t; before[p] = conc }
    }
    END {
      for (p in at) if (after[p] > 0 && !okafter[p] && before[p] == "success") {
        n = split(p, parts, "/"); name = parts[n]
        printf "%s has failed every run (%d) since it was changed on %s%s\n", name, after[p], day[p], (title[p] != "" ? " (" title[p] ")" : "")
      }
    }' | sort
}

# issues_without_state LINES
# Each line is "NUMBER label,label,...". Print the numbers whose labels
# include no "state:" label, one per line.
issues_without_state() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    NF >= 1 {
      labels = (NF >= 2) ? $2 : ""
      if ("," tolower(labels) "," !~ /,state:/) print $1
    }'
}

# issue_refs TEXT
# Print every issue number TEXT refers to as #N, one per line, unique.
issue_refs() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    {
      s = $0
      while (match(s, /#[0-9]+/)) {
        n = substr(s, RSTART + 1, RLENGTH - 1)
        if (!(n in seen)) { seen[n] = 1; print n }
        s = substr(s, RSTART + RLENGTH)
      }
    }'
}

# ended_remote_branches REMOTE ENDED [DEFAULT]
# REMOTE is one remote branch name per line; ENDED is the head branch of
# each merged or closed pull request. Print the remote branches whose
# pull request has ended, one per line, never the default branch.
ended_remote_branches() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v ended="$2" -v def="${3:-main}" '
    BEGIN { n = split(ended, e, "\n"); for (i = 1; i <= n; i++) { b = e[i]; gsub(/^[ \t]+|[ \t\r]+$/, "", b); if (b != "") done[b] = 1 } }
    $0 != "" && $0 != def && ($0 in done) && !seen[$0]++ { print }'
}

# audit_comment MISSING STALE [RED]
# MISSING is issue numbers one per line; STALE is "PR ISSUE" pairs one per
# line; RED is the numbers of open red-main issues, one per line. Print the
# comment body, or nothing when all are empty.
audit_comment() {
  ac_missing=$(printf '%s\n' "$1" | sed '/^[ \t]*$/d')
  ac_stale=$(printf '%s\n' "$2" | sed '/^[ \t]*$/d')
  ac_red=$(printf '%s\n' "${3:-}" | sed '/^[ \t]*$/d')
  ac_branches=$(printf '%s\n' "${4:-}" | sed '/^[ \t]*$/d')
  [ -n "$ac_missing" ] || [ -n "$ac_stale" ] || [ -n "$ac_red" ] || [ -n "$ac_branches" ] || return 0
  ac_sep=""
  if [ -n "$ac_red" ]; then
    printf 'Main is red and the issue is still open:\n'
    printf '%s\n' "$ac_red" | awk '{ printf "- #%s\n", $1 }'
    ac_sep="\n"
  fi
  if [ -n "$ac_missing" ]; then
    printf "$ac_sep"
    printf 'Open issues with no State label:\n'
    printf '%s\n' "$ac_missing" | awk '{ printf "- #%s\n", $1 }'
    ac_sep="\n"
  fi
  if [ -n "$ac_stale" ]; then
    printf "$ac_sep"
    printf 'Issues still open and labeled ready after their PR merged:\n'
    printf '%s\n' "$ac_stale" | awk '{ printf "- #%s (merged in #%s)\n", $2, $1 }'
    ac_sep="\n"
  fi
  if [ -n "$ac_branches" ]; then
    printf "$ac_sep"
    printf '%s\n' "$ac_branches" | awk '
      { b[NR] = $0 }
      END {
        printf "%d branch(es) are still on the remote after their pull request merged or closed. Their worktrees, if any, are leftovers; run sh scripts/worktrees.sh audit locally.\n", NR
        for (i = 1; i <= NR && i <= 5; i++) printf "- %s\n", b[i]
        if (NR > 5) printf "- and %d more\n", NR - 5
      }'
  fi
}
