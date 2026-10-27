#!/bin/sh
# Pure helpers for the template refresh. Text in, text out.

# owned_paths OWNED
# OWNED is the text of templates/OWNED.txt. Print the plugin-owned paths,
# one per line.
owned_paths() {
  printf '%s\n' "$1" | tr -d '\r' | awk 'NF && $1 !~ /^#/ && $1 != "default" && $1 != "feature" { print $1 }'
}

# owned_features OWNED
# Each plugin-owned path with its feature, "feature<TAB>path", one per line,
# from the "feature NAME" lines that group them. A path before any feature
# line is in "core".
owned_features() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    $1 == "feature" && NF >= 2 { f = $2; next }
    NF && $1 !~ /^#/ && $1 != "default" { printf "%s\t%s\n", (f == "" ? "core" : f), $1 }'
}

# feature_of FEATURES PATH
# The feature PATH belongs to, from owned_features' output.
feature_of() {
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2 == p { print $1; exit }'
}

# adopted_features FEATURES PRESENT
# The features a project uses: those whose anchor, the first file listed
# for the feature, is in PRESENT (one path per line). Space separated, in
# order. One stray file is not use: a project with the plugin's audit
# workflow and its own board-state script does not use the plugin's board.
adopted_features() {
  printf '%s\n' "$1" | awk -F'\t' -v present="$2" '
    BEGIN { n = split(present, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") have[a[i]] = 1 }
    NF >= 2 { if (!($1 in seen)) { seen[$1] = 1; order[++c] = $1; if ($2 in have) used[$1] = 1 } }
    END { s = ""; for (i = 1; i <= c; i++) if (order[i] in used) s = s (s == "" ? "" : " ") order[i]; print s }'
}

# default_paths OWNED [FEATURE]
# The config files with defaults: added when missing, never replaced. A
# default belongs to the feature it is listed under (core before any
# feature line); with FEATURE, only that feature's.
default_paths() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v want="${2:-}" '
    $1 == "feature" && NF >= 2 { f = $2; next }
    $1 == "default" && NF >= 2 { cur = (f == "" ? "core" : f); if (want == "" || cur == want) print $2 }'
}

# same_text A B
# "yes" when two texts are equal ignoring carriage returns and a trailing
# newline, "no" otherwise. A Windows checkout is not a change.
same_text() {
  st_a=$(printf '%s' "$1" | tr -d '\r')
  st_b=$(printf '%s' "$2" | tr -d '\r')
  if [ "$st_a" = "$st_b" ]; then echo yes; else echo no; fi
}

# workflow_jobs YAML
# The job names a workflow defines: keys indented two spaces under "jobs:".
workflow_jobs() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^jobs:[ \t]*$/ { in_jobs = 1; next }
    /^[^ \t#]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[ \t]*$/ { k = $1; sub(/:$/, "", k); print k }'
}

# missing_jobs TEMPLATE_YAML PROJECT_YAML
# Jobs the template workflow has that the project's copy does not. The
# project owns its ci.yml, so these are reported, not added.
missing_jobs() {
  mj_have=$(workflow_jobs "$2")
  workflow_jobs "$1" | while IFS= read -r mj_j; do
    printf '%s\n' "$mj_have" | grep -qxF "$mj_j" || printf '%s\n' "$mj_j"
  done
}

# split_checks PROJECT_YML
# The cheap rule checks a project's ci.yml still runs as jobs of their
# own, one per line. Before 0.9.8 the template ran each as its own job;
# on self-hosted runners every job pays a pickup and a checkout, and ten
# jobs on two runners queued ten minutes for two of work. Two or more
# such jobs are worth moving into one "checks" job; fewer print nothing.
split_checks() {
  sc_have=$(workflow_jobs "$1")
  sc_out=$(for sc_j in classify line-endings status-page numbering-check spec-check setup-check shared-check; do
    printf '%s\n' "$sc_have" | grep -qxF "$sc_j" && printf '%s\n' "$sc_j"
  done)
  [ "$(printf '%s' "$sc_out" | grep -c .)" -ge 2 ] && printf '%s\n' "$sc_out"
  return 0
}

# missing_lines TEMPLATE PROJECT
# Lines of a template file (not comments, not blank) that the project's
# copy lacks, such as an attribute in .gitattributes or a path in
# .gitignore. Reported, not added.
missing_lines() {
  ml_have=$(printf '%s\n' "$2" | tr -d '\r')
  printf '%s\n' "$1" | tr -d '\r' | awk 'NF && $0 !~ /^[ \t]*#/' | while IFS= read -r ml_l; do
    printf '%s\n' "$ml_have" | grep -qxF "$ml_l" || printf '%s\n' "$ml_l"
  done
}

# workflow_needs TEXT
# The secrets and variables a workflow reads, from its ${{ secrets.X }} and
# ${{ vars.X }} expressions: one line, "secrets A, B; variables C", or
# nothing when it reads none. The sync prints it for each workflow it
# adds, so the owner knows what to set before the first run.
workflow_needs() {
  wn_s=$(printf '%s\n' "$1" | grep -o 'secrets\.[A-Z0-9_]*' | sed 's/secrets\.//' | sort -u | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  wn_v=$(printf '%s\n' "$1" | grep -o 'vars\.[A-Z0-9_]*' | sed 's/vars\.//' | sort -u | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  [ -n "$wn_s" ] && printf 'secrets %s' "$wn_s"
  [ -n "$wn_s" ] && [ -n "$wn_v" ] && printf '; '
  [ -n "$wn_v" ] && printf 'variables %s' "$wn_v"
  { [ -n "$wn_s" ] || [ -n "$wn_v" ]; } && echo
  return 0
}

# ci_runs_on TEXT
# The first "runs-on:" value in a workflow that is a plain value, as
# written ("ubuntu-latest" or "[self-hosted, windows]"), or nothing when
# there is none. Placeholders and expressions are skipped: one project's
# first runs-on read another job's outputs, and copying it would have
# broken the workflow it was copied into.
ci_runs_on() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[ \t]*runs-on:[ \t]*//p' | sed 's/[ \t]*#.*//; s/[ \t]*$//' | awk '$0 != "" && $0 != "RUNS_ON" && index($0, "${{") == 0 { print; exit }'
}

# ci_shell TEXT
# The first "shell:" value in a workflow, quotes kept, or nothing when it
# is absent or still the RUN_SHELL placeholder.
ci_shell() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[ \t]*shell:[ \t]*//p' | sed 's/[ \t]*$//' | awk '$0 != "" && $0 != "RUN_SHELL" { print; exit }'
}

# filled_text TEXT RUNS_ON RUN_SHELL
# TEXT with the RUNS_ON and RUN_SHELL placeholders filled by the values
# given, each only when it is not empty: the template as this project would
# have it, so a workflow the sync filled compares as current, not edited.
filled_text() {
  ft_t=$1
  [ -n "$2" ] && ft_t=$(fill_lines "$ft_t" RUNS_ON "$2")
  [ -n "$3" ] && ft_t=$(fill_lines "$ft_t" RUN_SHELL "$3")
  printf '%s\n' "$ft_t"
}

# fill_lines TEXT NAME VALUE
# fill_placeholder on the lines that set a runner or a shell ("runs-on:",
# "shell:") and no other: a comment that names the placeholders stays as
# written, so unfill_text gives the template back. A filled comment once
# made every freshly synced workflow fail to match any released version,
# and the sync called it the project's own.
fill_lines() {
  fl_out=""
  while IFS= read -r fl_line || [ -n "$fl_line" ]; do
    case "$fl_line" in
      *runs-on:*|*shell:*) fl_line=$(fill_placeholder "$fl_line" "$2" "$3") ;;
    esac
    fl_out="$fl_out$fl_line
"
  done <<FLEOF
$1
FLEOF
  printf '%s' "$fl_out"
}

# fill_placeholder TEXT NAME VALUE
# TEXT with every occurrence of NAME replaced by VALUE, literally: VALUE
# goes in through the environment, never through awk -v or a format
# string, which both turn "\b" into a backspace byte; and the replacement
# is by position, never gsub, so "&" and backslashes in VALUE are kept.
# A Windows shell path once lost its backslashes this way and GitHub
# refused the workflow. Only a whole word is replaced: NAME inside a longer
# name (RUNS_ON in DEPLOY_RUNS_ON) is left alone.
fill_placeholder() {
  FP_NAME=$2 FP_VALUE=$3 awk '
    function word(c) { return c ~ /[A-Za-z0-9_]/ }
    BEGIN { name = ENVIRON["FP_NAME"]; val = ENVIRON["FP_VALUE"]; n = length(name) }
    {
      line = $0; out = ""
      while (n > 0 && (i = index(line, name)) > 0) {
        before = (i > 1) ? substr(line, i - 1, 1) : ""; after = substr(line, i + n, 1)
        if (word(before) || word(after)) { out = out substr(line, 1, i + n - 1) }
        else { out = out substr(line, 1, i - 1) val }
        line = substr(line, i + n)
      }
      print out line
    }' <<FPEOF
$1
FPEOF
}

# control_bytes TEXT
# Print "yes" when TEXT holds a control character other than tab or
# newline, which no workflow file should; "no" otherwise. The sync checks
# a workflow it wrote before committing it.
control_bytes() {
  if printf '%s' "$1" | LC_ALL=C tr -d '\011\012\015' | LC_ALL=C grep -q '[[:cntrl:]]'; then echo yes; else echo no; fi
}

# per_merge_release WORKFLOW_TEXT
# Print "yes" when a workflow starts on workflow_run of CI: then every
# merge to main builds and ships a release. One project uploaded 29 Play
# versions in an afternoon that way, each a full Gradle build on a
# self-hosted runner. A release follows Deploy (workflow_run of Deploy,
# plus workflow_dispatch), which the queue starts once per drain.
per_merge_release() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^[ \t]*workflow_run:/ { inrun = 1; next }
    inrun && /^[ \t]*workflows:/ { if ($0 ~ /[\[ ,"\x27]CI[\] ,"\x27]|[\[ ,"\x27]CI$/) found = 1 }
    inrun && /^[^ \t]/ { inrun = 0 }
    END { if (found) print "yes" }'
}

# deploy_path_of DEPLOY_JSON
# The "path" a project's .claude/deploy.json names (runner, vercel or
# guard), or nothing.
deploy_path_of() {
  printf '%s' "$1" | tr -d '\r\n' | sed -n 's/.*"path"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p'
}

# release_workflows DEPLOY_JSON
# The release workflows a project lists in .claude/deploy.json under
# "releases" (["play-internal.yml", "app-distribution.yml"]), one a line.
release_workflows() {
  printf '%s' "$1" | tr -d '\r\n' | sed -n 's/.*"releases"[ \t]*:[ \t]*\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | sed 's/[" \t]//g; /^$/d'
}

# norm_hash TEXT
# A content hash of TEXT that ignores carriage returns and trailing
# newlines, the same way same_text does, so a Windows checkout of a file
# hashes as its template does.
norm_hash() {
  printf '%s\n' "$1" | tr -d '\r' | git hash-object --stdin
}

# unfill_text TEXT RUNS_ON RUN_SHELL
# TEXT with a "runs-on:" line whose value is exactly RUNS_ON, and a
# "shell:" line whose value is exactly RUN_SHELL, put back to the
# placeholders: a workflow the sync filled, as its template was. An empty
# value leaves its lines alone.
unfill_text() {
  UF_RO=$2 UF_RS=$3 awk '
    function rest(line, key,   i) { i = index(line, key); return substr(line, i + length(key)) }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    {
      line = $0
      if (ENVIRON["UF_RO"] != "" && line ~ /^[ \t]*runs-on:/ && trim(rest(line, "runs-on:")) == ENVIRON["UF_RO"]) {
        sub(/runs-on:.*/, "runs-on: RUNS_ON", line)
      } else if (ENVIRON["UF_RS"] != "" && line ~ /^[ \t]*shell:/ && trim(rest(line, "shell:")) == ENVIRON["UF_RS"]) {
        sub(/shell:.*/, "shell: RUN_SHELL", line)
      }
      print line
    }' <<UFEOF
$1
UFEOF
}

# known_match KNOWN PATH TEXT RUNS_ON RUN_SHELL
# "yes" when TEXT is a released version of the plugin file PATH: its hash,
# as written or with the project's runner and shell put back to their
# placeholders, is a "PATH HASH" line of KNOWN (templates/KNOWN.txt).
known_match() {
  km_a=$(norm_hash "$3")
  km_b=$(norm_hash "$(unfill_text "$3" "$4" "$5")")
  km_c=$(norm_hash "$(unfill_text "$(unfill_comments "$(unfill_comments "$3" RUNS_ON "$4")" RUN_SHELL "$5")" "$4" "$5")")
  if printf '%s\n' "$1" | grep -qxF -e "$2 $km_a" -e "$2 $km_b" -e "$2 $km_c"; then echo yes; else echo no; fi
}

# unfill_comments TEXT NAME VALUE
# TEXT with VALUE put back to NAME on its comment lines only. Syncs before
# 0.23.3 filled the placeholders wherever they stood, comments included,
# and a workflow they wrote matches a released version only this way. An
# occurrence inside a word or in quotes is left alone: a comment that says
# a bare "bash" is the WSL stub was written so, not filled. An empty VALUE
# leaves the text alone.
unfill_comments() {
  [ -n "$3" ] || { printf '%s\n' "$1"; return 0; }
  UC_NAME=$2 UC_VALUE=$3 awk '
    function edge(c) { return c ~ /[A-Za-z0-9_"\x27]/ }
    BEGIN { name = ENVIRON["UC_NAME"]; val = ENVIRON["UC_VALUE"]; n = length(val) }
    {
      line = $0
      if (line ~ /^[ \t]*#/) {
        out = ""
        while ((i = index(line, val)) > 0) {
          if (edge(substr(line, i - 1, 1)) || edge(substr(line, i + n, 1))) { out = out substr(line, 1, i + n - 1) }
          else { out = out substr(line, 1, i - 1) name }
          line = substr(line, i + n)
        }
        line = out line
      }
      print line
    }' <<UCEOF
$1
UCEOF
}

# sourced_scripts TEXT
# The repository scripts a workflow sources or runs (". scripts/x.sh",
# "sh scripts/x.sh"), one per line, except those it first tests for with
# "-f scripts/x.sh": a guarded one is optional. A workflow written without
# a script it needs fails on every run, and one sync once did that to a
# project that had its own board tools.
sourced_scripts() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    {
      line = $0
      while (match(line, /-f[ \t]+scripts\/[A-Za-z0-9_.\/-]+/)) {
        g = substr(line, RSTART, RLENGTH); sub(/^-f[ \t]+/, "", g); guarded[g] = 1
        line = substr(line, RSTART + RLENGTH)
      }
      line = $0
      while (match(line, /(^|[ \t;&|(])(\.|sh)[ \t]+scripts\/[A-Za-z0-9_.\/-]+/)) {
        s = substr(line, RSTART, RLENGTH); sub(/^.*(\.|sh)[ \t]+/, "", s); sub(/\.+$/, "", s)
        if (!(s in seen)) { seen[s] = 1; order[++n] = s }
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { for (i = 1; i <= n; i++) if (!(order[i] in guarded)) print order[i] }'
}

# here_scripts TEXT DIR
# The scripts a script loads from its own folder (". \"$here/x.sh\""), as
# paths under DIR, one per line: runner-doctor.sh loads doctor-lib.sh this
# way, and one without the other fails.
here_scripts() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v dir="$2" '
    {
      line = $0
      while (match(line, /\$here\/[A-Za-z0-9_.-]+/)) {
        s = substr(line, RSTART + 6, RLENGTH - 6); sub(/\.+$/, "", s)
        if (!(s in seen)) { seen[s] = 1; print dir "/" s }
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

# loaded_scripts TEXT
# The repository scripts a script loads (a line that starts with
# ". scripts/x.sh"), one per line. A command a script only prints for a
# person ("run sh scripts/worktrees.sh") is not one of its own.
loaded_scripts() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^[ \t]*\.[ \t]+scripts\// {
      s = $0; sub(/^[ \t]*\.[ \t]+/, "", s); sub(/[ \t;].*$/, "", s); sub(/\.+$/, "", s)
      if (!(s in seen)) { seen[s] = 1; print s }
    }'
}

# new_template_files ALL LISTED
# Template files under scripts/ that OWNED.txt does not list, one per line.
# ALL is every path in templates/, LISTED the owned and default paths. A
# file added to the templates in a later version and never listed was never
# compared, so it never arrived: a project synced to 0.24.0 was told every
# file was current while three new check scripts were missing.
new_template_files() {
  NT_ALL="$1" NT_LISTED="$2" awk 'BEGIN {
    n = split(ENVIRON["NT_LISTED"], l, "\n"); for (i = 1; i <= n; i++) { sub(/\r$/, "", l[i]); if (l[i] != "") have[l[i]] = 1 }
    n = split(ENVIRON["NT_ALL"], a, "\n")
    for (i = 1; i <= n; i++) { p = a[i]; sub(/\r$/, "", p); if (p ~ /^scripts\// && !(p in have)) print p }
  }'
}

# The step parser both step helpers share: for each line of a workflow, the
# job it is in and, inside that job's steps, which step it belongs to and
# that step's name.
_steps_awk='
function indent(s) { match(s, /^ */); return RLENGTH }
function parse(text, pre,    n, ln, i, line, job, insteps, injobs, k, nm) {
  n = split(text, ln, "\n"); job = ""; insteps = 0; injobs = 0; k = 0
  for (i = 1; i <= n; i++) {
    line = ln[i]; sub(/\r$/, "", line)
    L[pre, i] = line; J[pre, i] = ""; S[pre, i] = 0
    if (line ~ /^jobs:[ \t]*$/) { injobs = 1; job = ""; continue }
    if (line ~ /^[^ \t#]/) { injobs = 0; job = ""; insteps = 0; continue }
    if (injobs && line ~ /^  [A-Za-z0-9_-]+:[ \t]*$/) { job = line; sub(/^  /, "", job); sub(/:.*/, "", job); insteps = 0; continue }
    if (job == "") continue
    if (line ~ /^    steps:[ \t]*$/) { insteps = 1; continue }
    if (insteps && line !~ /^[ \t]*$/ && indent(line) <= 4) insteps = 0
    if (!insteps) continue
    J[pre, i] = job
    if (line ~ /^      - /) { k++; SN[pre, k] = ""; SJ[pre, k] = job }
    S[pre, i] = k
    nm = line
    if (k && (nm ~ /^      - name:/ || nm ~ /^        name:/)) {
      sub(/^ *-? *name:[ \t]*/, "", nm); sub(/[ \t]+$/, "", nm); gsub(/^["\047]|["\047]$/, "", nm)
      SN[pre, k] = nm
    }
    if (k && line ~ /^ *(- )?run:[ \t]*echo[ \t]+["\047]?[Rr]eplace with/) SP[pre, k] = 1
  }
  N[pre] = n; K[pre] = k
}
function load(    k, j, pj, prev) {
  parse(ENVIRON["ST_T"], "t"); parse(ENVIRON["ST_P"], "p")
  for (k = 1; k <= K["p"]; k++) { pjob[SJ["p", k]] = 1; if (SN["p", k] != "") phave[SJ["p", k], SN["p", k]] = 1 }
  prev = ""; pj = ""
  for (k = 1; k <= K["t"]; k++) {
    j = SJ["t", k]; if (j != pj) { prev = ""; pj = j }
    if (SN["t", k] != "" && (j in pjob) && !((j, SN["t", k]) in phave)) { miss[k] = 1; mprev[k] = prev; if (SP["t", k]) ph[k] = 1 }
    if (SN["t", k] != "") prev = SN["t", k]
  }
}'

# missing_steps TEMPLATE_YAML PROJECT_YAML
# Named steps of a template job that the project's same job lacks, as
# "job<TAB>step name", one per line, with a third field "placeholder" when
# the template's step only holds a placeholder (an echo of "replace with
# ...", which a project replaces at bootstrap with its own steps) and so is
# not carried. Jobs the project lacks are not here;
# missing_jobs names those.
missing_steps() {
  ST_T="$1" ST_P="$2" awk "$_steps_awk"'
  BEGIN { load(); for (k = 1; k <= K["t"]; k++) if (k in miss) printf "%s\t%s%s\n", SJ["t", k], SN["t", k], (k in ph) ? "\tplaceholder" : "" }'
}

# carry_steps TEMPLATE_YAML PROJECT_YAML
# The project's workflow with each step missing_steps names carried in from
# the template, whole, after the step that comes before it in the template
# (by name), or at the end of the job's steps when that one is not here.
# Everything else in the project's copy stays as it is: a project that had
# edited its ci.yml kept it whole and never got the mock check's step.
carry_steps() {
  ST_T="$1" ST_P="$2" awk "$_steps_awk"'
  function emit(j, after,    k, i) {
    for (k = 1; k <= K["t"]; k++) if ((k in miss) && !(k in ph) && !(k in done) && SJ["t", k] == j && (after == "\001" || mprev[k] == after)) {
      done[k] = 1
      for (i = 1; i <= N["t"]; i++) if (S["t", i] == k) print L["t", i]
      if (after != "\001") emit(j, SN["t", k])
    }
  }
  function close_step() { if (cur) { emit(SJ["p", cur], SN["p", cur]); cur = 0 } }
  BEGIN {
    load(); cur = 0; cj = ""; nb = 0
    for (i = 1; i <= N["p"]; i++) {
      line = L["p", i]
      if (J["p", i] != "" && line ~ /^[ \t]*$/) { blank[++nb] = line; continue }
      if (S["p", i] != cur) close_step()
      if (cj != "" && J["p", i] != cj) { emit(cj, "\001") }
      for (b = 1; b <= nb; b++) print blank[b]; nb = 0
      cj = J["p", i]; cur = S["p", i]
      print line
    }
    close_step(); if (cj != "") emit(cj, "\001")
    for (b = 1; b <= nb; b++) print blank[b]
  }'
}
