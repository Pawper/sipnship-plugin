#!/bin/sh
# Pure helpers shared by the hook scripts. Nothing here reads a file or
# touches the network, so every function can be tested by feeding it strings.
# Needs only POSIX sh and awk, which Git Bash, macOS and Linux all have.

# json_field JSON KEY
# Print the string value of the first "KEY" in JSON with its escapes undone.
# Prints nothing when the key is missing or its value is not a string.
json_field() {
  printf '%s' "$1" | awk -v key="\"$2\"" '
    BEGIN { RS = "\001" }
    {
      i = index($0, key)
      if (i == 0) exit
      s = substr($0, i + length(key))
      if (!sub(/^[ \t\r\n]*:[ \t\r\n]*/, "", s)) exit
      if (substr(s, 1, 1) != "\"") exit
      n = length(s)
      out = ""
      for (j = 2; j <= n; j++) {
        c = substr(s, j, 1)
        if (c == "\\") {
          j++
          d = substr(s, j, 1)
          if (d == "n") out = out "\n"
          else if (d == "t") out = out "\t"
          else if (d == "r") out = out "\r"
          else if (d == "u") { out = out "?"; j += 4 }
          else out = out d
        } else if (c == "\"") {
          break
        } else {
          out = out c
        }
      }
      printf "%s", out
    }'
}

# split_commands COMMAND
# Print one simple command per line: the input split on &&, ||, ;, |, newlines,
# subshells and backticks, with leading VAR=value assignments and wrappers such
# as sudo, env, time and exec removed. Quotes are not parsed; this errs toward
# seeing more commands, never fewer.
# mask_command COMMAND
# The command with heredoc bodies dropped, continued lines joined, and
# separators inside quoted strings neutralized: the text every check reads
# before it is cut into simple commands.
mask_command() {
  printf '%s\n' "$1" | awk '
    # Pass 1: drop heredoc bodies (text is data, not commands) and join
    # lines that end in a backslash, so a command written over several
    # lines is judged whole.
    function unquote(w) { gsub(/["'\'']/, "", w); return w }
    # opens(s): how many more "(" than ")" the text holds. A heredoc opened
    # inside a command substitution, such as --body "$(cat <<EOF ... EOF)",
    # leaves its command unfinished until the substitution closes, so the
    # line is held and the lines after the terminator are joined onto it.
    function opens(s,   a, b) { a = gsub(/\(/, "(", s); b = gsub(/\)/, ")", s); return a - b }
    function emit(s) { gsub(/\$\([^)]*\)/, "SUBST", s); gsub(/[ \t]+/, " ", s); print s }
    {
      line = $0
      sub(/\r$/, "", line)
      if (inhere) {
        check = line
        if (dash) sub(/^\t+/, "", check)
        if (check == word) { inhere = 0; if (held != "") joinheld = 1 }
        next
      }
      if (joinheld) {
        held = held " " line
        if (opens(held) <= 0) { emit(held); held = ""; joinheld = 0 }
        next
      }
      if (joining) { buf = buf " " line; gsub(/[ \t]+/, " ", buf) } else { buf = line }
      joining = 0
      if (buf ~ /\\$/) { sub(/\\$/, "", buf); joining = 1; next }
      if (match(buf, /<<-?[ \t]*["'\'']?[A-Za-z_][A-Za-z0-9_]*["'\'']?/)) {
        tok = substr(buf, RSTART, RLENGTH)
        dash = (tok ~ /^<<-/)
        sub(/^<<-?[ \t]*/, "", tok)
        word = unquote(tok)
        inhere = 1
        if (opens(buf) > 0) { held = buf; next }
      }
      print buf
    }
    END { if (held != "") emit(held); if (joining && buf != "") print buf }' | awk '
    # Pass 2: inside a quoted string, separators are text, not syntax. A
    # --body "..." spread over lines, or holding ; & | ( ) < > or a
    # backtick, must not cut the command apart, or the flags after it land
    # in another fragment. Such characters inside quotes become "_" and
    # newlines become spaces. Inside double quotes, $( ... ) is still code,
    # so an rm hidden in "$(rm -rf x)" is still seen.
    BEGIN { RS = "\001" }
    function mask(c) { if (c == "\n" || c == "\r") return " "; if (index(";&|()`<>", c)) return "_"; return c }
    {
      s = $0; out = ""; q = ""; d = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "s") { if (c == "\047") q = ""; out = out ((c == "\047") ? c : mask(c)); continue }
        if (q == "d") {
          if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
          if (c == "$" && substr(s, i + 1, 1) == "(") { q = "c"; d = 1; out = out "$("; i++; continue }
          if (c == "\"") { q = ""; out = out c; continue }
          out = out mask(c); continue
        }
        if (q == "c") {
          if (c == "(") d++
          if (c == ")") { d--; if (d == 0) { q = "d"; out = out c; continue } }
          out = out c; continue
        }
        if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
        if (c == "\047") { q = "s"; out = out c; continue }
        if (c == "\"") { q = "d"; out = out c; continue }
        out = out c
      }
      printf "%s", out
    }'
}

split_commands() {
  mask_command "$1" | awk '
    { gsub(/&&|\|\||;|\||\$\(|`|\(|\)|\{|\}/, "\n"); print }' | awk '
    {
      line = $0
      sub(/^[ \t\r]+/, "", line)
      while (line ~ /^([A-Za-z_][A-Za-z0-9_]*=[^ \t]*|sudo|command|exec|nohup|time|env|busybox)[ \t]+/) {
        sub(/^[^ \t]+[ \t]+/, "", line)
      }
      sub(/[ \t\r]+$/, "", line)
      if (line != "") print line
    }'
}

# delete_reason COMMAND
# Print the delete command found (rm, rmdir, del, erase, rd, Remove-Item, ri,
# git clean), including inside a cmd or powershell wrapper. Print nothing when
# the command does not delete.
delete_reason() {
  split_commands "$1" | awk '
    {
      line = $0
      first = line
      sub(/[ \t].*/, "", first)
      sub(/.*[\/\\]/, "", first)
      lower = tolower(first)
      sub(/\.exe$/, "", lower)
      rest = line
      sub(/^[^ \t]+[ \t]*/, "", rest)
      if (lower ~ /^(rm|rmdir|del|erase|rd|remove-item|ri)$/) { print first; exit }
      if (lower == "git") {
        r = tolower(rest)
        if (r ~ /^clean([ \t]|$)/) { print "git clean"; exit }
      }
      if (lower ~ /^(cmd|powershell|pwsh)$/) {
        r = tolower(rest)
        if (match(r, /(^|[ \t"'\''])(rm|rmdir|del|erase|rd|remove-item|ri)([ \t"'\'']|$)/)) {
          m = substr(r, RSTART, RLENGTH)
          gsub(/[^a-z-]/, "", m)
          print m
          exit
        }
      }
    }'
}

# force_push_reason COMMAND
# Print the flag or refspec that makes a git push forced (--force,
# --force-with-lease, --force-if-includes, -f, a combined short flag with f,
# or a + refspec). Print nothing otherwise.
force_push_reason() {
  split_commands "$1" | awk '
    {
      line = $0
      gsub(/["'\'']/, "", line)
      n = split(line, t, /[ \t]+/)
      if (t[1] != "git") next
      i = 2
      while (i <= n && t[i] ~ /^-/) {
        if (t[i] == "-C" || t[i] == "-c") i++
        i++
      }
      if (t[i] != "push") next
      for (j = i + 1; j <= n; j++) {
        if (t[j] ~ /^--force($|=)/ || t[j] ~ /^--force-with-lease/ || t[j] == "--force-if-includes" || t[j] ~ /^-[a-zA-Z]*f[a-zA-Z]*$/ || t[j] ~ /^\+/) {
          print t[j]
          exit
        }
      }
    }'
}

# full_sweep_reason COMMAND
# Print the test runner invocation when it would run the whole suite: a known
# runner with no file, directory, pattern or filter after it. Print nothing
# when the run is targeted or the command is not a test runner.
full_sweep_reason() {
  split_commands "$1" | awk '
    function is_target_flag(a) {
      return a ~ /^(-k|-t|-g|-m|-n|--grep|--filter|--testNamePattern|--testPathPattern|--test-name-pattern|--run|--tests|--trait|-Dtest=|--match|--name|--spec|--only)/
    }
    {
      line = $0
      gsub(/["'\'']/, "", line)
      n = split(line, t, /[ \t]+/)
      i = 1
      while (i <= n) {
        if (t[i] ~ /^(npx|bunx)$/) { i++; while (i <= n && t[i] ~ /^-/) i++; continue }
        if ((t[i] == "pnpm" || t[i] == "yarn") && (t[i + 1] == "exec" || t[i + 1] == "dlx")) { i += 2; continue }
        if (t[i] ~ /^(uv|poetry|pipenv|bundle|hatch|pdm)$/ && (t[i + 1] == "run" || t[i + 1] == "exec")) { i += 2; continue }
        if (t[i] ~ /^python[0-9.]*(\.exe)?$/ && t[i + 1] == "-m") { i += 2; continue }
        break
      }
      if (i > n) next
      runner = t[i]
      sub(/.*[\/\\]/, "", runner)
      sub(/\.exe$/, "", runner)
      start = 0
      label = ""
      if (runner ~ /^(npm|yarn|pnpm|bun)$/) {
        j = i + 1
        if (t[j] == "run" || t[j] == "run-script") j++
        if (t[j] == "test" || t[j] == "t" || t[j] == "tst") { start = j + 1; label = runner " " t[j] } else next
      } else if (runner ~ /^(pytest|py\.test|jest|vitest|mocha|ava|tap|rspec|phpunit|ctest|unittest|nose2|karma|playwright|cypress)$/) {
        start = i + 1
        label = runner
      } else if (runner ~ /^(cargo|go|dotnet|mvn|gradle|gradlew|make|rake|mix|swift|flutter|dart|stack)$/ && t[i + 1] == "test") {
        start = i + 2
        label = runner " test"
      } else {
        next
      }
      pos = 0
      for (j = start; j <= n; j++) {
        a = t[j]
        if (a == "" || a == "--") continue
        if (is_target_flag(a)) { pos++; continue }
        if (a ~ /^-/) continue
        if (a ~ /^(run|watch|test|spec)$/) continue
        if (a == "./..." || a == "..." || a == ".") continue
        pos++
      }
      if (pos == 0) { print label; exit }
    }'
}

# generated_page_reason FILE_PATH PROJECT_DIR PATTERNS
# PATTERNS is one shell glob per line; blank lines and # comments are skipped.
# A pattern without a slash is matched against the file name, a pattern with a
# slash against the path relative to PROJECT_DIR. Print the relative path when
# it matches a pattern, nothing otherwise.
generated_page_reason() {
  gp_path=$(printf '%s' "$1" | tr '\\' '/')
  gp_root=$(printf '%s' "$2" | tr '\\' '/')
  gp_root=${gp_root%/}
  gp_rel=$gp_path
  case "$gp_path" in
    "$gp_root"/*) gp_rel=${gp_path#"$gp_root"/} ;;
  esac
  gp_base=${gp_rel##*/}
  printf '%s\n' "$3" | tr -d '\r' | tr '\\' '/' | while IFS= read -r gp_pat; do
    case "$gp_pat" in ''|'#'*) continue ;; esac
    case "$gp_pat" in
      */*)
        case "$gp_rel" in $gp_pat|*/$gp_pat) printf '%s\n' "$gp_rel"; break ;; esac
        ;;
      *)
        case "$gp_base" in $gp_pat) printf '%s\n' "$gp_rel"; break ;; esac
        ;;
    esac
  done
}

# task_tier SUBAGENT_TYPE DESCRIPTION PROMPT
# Print the tier a dispatched task needs: lookup, routine or hard.
# A lookup finds, lists or reads something and has a short prompt. A hard
# task designs, implements, debugs, reviews or plans. Everything else is
# routine.
task_tier() {
  tt_type=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  tt_text=$(printf '%s %s' "$2" "$3" | tr 'A-Z' 'a-z')
  tt_words=$(printf '%s' "$3" | wc -w | tr -d ' ')
  case "$tt_type" in
    explore|claude-code-guide) echo lookup; return 0 ;;
    plan) echo hard; return 0 ;;
  esac
  if printf '%s' "$tt_text" | grep -Eq '(design|architect|refactor|implement|build|debug|fix|review|audit|security|prove|migrat|plan)'; then
    echo hard
    return 0
  fi
  if [ "$tt_words" -le 120 ] && printf '%s' "$tt_text" | grep -Eq '(find|search|locate|list|grep|where is|look up|lookup|which file|read|check whether|does .* exist|count)'; then
    echo lookup
    return 0
  fi
  echo routine
}

# gh_refusal TEXT
# Print "yes" when gh's error output means GitHub refused the call for a
# rate limit rather than the user being signed out: "rate limit",
# "secondary", "abuse", or the "unknown owner type" that gh project prints
# when its GraphQL query is refused. Print "no" otherwise.
gh_refusal() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    *"rate limit"*|*"secondary"*|*"abuse"*|*"unknown owner type"*) echo yes ;;
    *) echo no ;;
  esac
}

# long_command_reason COMMAND DESCRIPTION [MAX_LINES] [MAX_CHARS]
# Print why a Bash call should be a script file and a title instead: "N
# lines" or "N characters" when COMMAND runs past MAX_LINES (default 12)
# or MAX_CHARS (default 1000), or "no description" when DESCRIPTION is
# empty. A forty-line program pasted into a heredoc fills the task window
# with its source and has no name; the same program in .scratch/, run by
# name with a one-line description, is a titled task and a file the rules
# already ask for. Print nothing when the call is short and titled.
# Quoted text is not code: a pull request body passed as -f body="..." is
# the common long call and is not what the limit is for, so the contents
# of single- and double-quoted strings are dropped before counting (the
# quote marks stay). A heredoc still counts; that is the program case.
code_only() {
  printf '%s' "$1" | awk '
    BEGIN { RS = "\001" }
    {
      s = $0; out = ""; q = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "s") { if (c == "\047") { q = ""; out = out c }; continue }
        if (q == "d") { if (c == "\\") { i++; continue } if (c == "\"") { q = ""; out = out c }; continue }
        if (c == "\047") { q = "s"; out = out c; continue }
        if (c == "\"") { q = "d"; out = out c; continue }
        out = out c
      }
      printf "%s", out
    }'
}

long_command_reason() {
  lc_code=$(code_only "$1")
  lc_lines=$(printf '%s\n' "$lc_code" | wc -l | tr -d ' ')
  lc_chars=$(printf '%s' "$lc_code" | wc -c | tr -d ' ')
  if [ "$lc_lines" -gt "${3:-12}" ]; then echo "$lc_lines lines"; return 0; fi
  if [ "$lc_chars" -gt "${4:-1000}" ]; then echo "$lc_chars characters"; return 0; fi
  [ -n "$(printf '%s' "$2" | tr -d ' \t\r\n')" ] || echo "no description"
}

# daemon_stop_reason COMMAND
# Print the command that stops a build daemon shared by every build on the
# machine: gradlew --stop, gradle --stop, nx reset, or a daemon kill
# (nx daemon --stop, dotnet build-server shutdown). On a machine that also
# hosts a self-hosted runner, that kills the runner's build mid-job. Print
# nothing otherwise, or when the command carries DAEMON_STOP_OK=1, which
# says no runner is on this machine.
daemon_stop_reason() {
  case "$1" in *DAEMON_STOP_OK=1*) return 0 ;; esac
  split_commands "$1" | awk '
    {
      line = $0
      gsub(/["'\'']/, "", line)
      n = split(line, t, /[ \t]+/)
      i = 1
      while (i <= n && t[i] ~ /^(npx|bunx|pnpm|yarn)$/) i++
      c = t[i]; sub(/.*[\/\\]/, "", c); sub(/\.(bat|cmd|exe)$/, "", c)
      if (c ~ /^(gradlew|gradle)$/) { for (j = i + 1; j <= n; j++) if (t[j] == "--stop") { print c " --stop"; exit } }
      if (c == "nx" && (t[i + 1] == "reset" || (t[i + 1] == "daemon" && t[i + 2] == "--stop"))) { print "nx " t[i + 1]; exit }
      if (c == "dotnet" && t[i + 1] == "build-server" && t[i + 2] == "shutdown") { print "dotnet build-server shutdown"; exit }
    }'
}

# model_rank MODEL
# Print 1 for haiku, 2 for sonnet, 3 for opus, 4 for fable, 0 for unknown.
model_rank() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    *haiku*) echo 1 ;;
    *sonnet*) echo 2 ;;
    *opus*) echo 3 ;;
    *fable*|*mythos*) echo 4 ;;
    *) echo 0 ;;
  esac
}

# agent_model_reason SUBAGENT_TYPE DESCRIPTION PROMPT MODEL
# Print "MODEL_TO_USE TIER" when a dispatch would waste usage: no model was
# set, or the model is heavier than the task's tier needs. Print nothing when
# the dispatch is fine. A lighter model than the tier suggests is allowed.
agent_model_reason() {
  am_tier=$(task_tier "$1" "$2" "$3")
  case "$am_tier" in
    lookup) am_want=haiku; am_rank=1 ;;
    routine) am_want=sonnet; am_rank=2 ;;
    *) am_want=opus; am_rank=3 ;;
  esac
  if [ -z "$4" ]; then
    printf '%s %s\n' "$am_want" "$am_tier"
    return 0
  fi
  if [ "$(model_rank "$4")" -gt "$am_rank" ]; then
    printf '%s %s\n' "$am_want" "$am_tier"
  fi
}

# workflow_model_reason SCRIPT
# Print the number of agent() calls that have no model when a workflow
# script dispatches agents without choosing a model for each. Print nothing
# when every call sets one or the script dispatches none.
workflow_model_reason() {
  wm_calls=$(printf '%s' "$1" | grep -o 'agent(' | wc -l | tr -d ' ')
  wm_models=$(printf '%s' "$1" | grep -o 'model[[:space:]]*:' | wc -l | tr -d ' ')
  [ "$wm_calls" -gt 0 ] || return 0
  if [ "$wm_models" -lt "$wm_calls" ]; then
    echo $((wm_calls - wm_models))
  fi
}

# batch_merge_reason COMMAND
# Print the number of PRs when the command runs merge-queue.sh with more
# than two PR numbers and names neither --batch nor --serial. Print nothing
# otherwise: a named mode is always allowed, and so are two or fewer PRs.
# stdin_wait_reason COMMAND
# Print the command that would sit waiting for input forever: the first
# command of a pipeline (the one reading the terminal) when it is cat, tee,
# head, tail, wc or sort with no file to read and no input redirected into
# it, or read with no input redirect. `cat >> /dev/null` is the shape that
# hung one agent's shell for fifteen hours. A command after a pipe is fed
# by the pipe and is fine. Print nothing otherwise.
stdin_wait_reason() {
  mask_command "$1" | awk '
    {
      t = $0
      gsub(/&&|\|\||;/, "\n", t)
      n = split(t, segs, "\n")
      for (k = 1; k <= n; k++) {
        first = segs[k]
        p = index(first, "|")
        if (p > 0) first = substr(first, 1, p - 1)
        sub(/^[ \t\r(]+/, "", first); sub(/[ \t\r)]+$/, "", first)
        m = split(first, w, /[ \t]+/)
        if (m < 1 || w[1] == "") continue
        c = w[1]; sub(/.*\//, "", c)
        if (c !~ /^(cat|tee|head|tail|wc|sort|read)$/) continue
        files = 0; fed = 0
        for (i = 2; i <= m; i++) {
          a = w[i]
          if (a ~ /^</) { fed = 1; if (a == "<" || a == "<<" || a == "<<<") i++; continue }
          if (a ~ /^[0-9&]*>/) { if (a ~ /^[0-9&]*>>?$/) i++; continue }
          if (a ~ /^-/) continue
          files++
        }
        if (fed) continue
        if (c == "read" || c == "tee" || files == 0) { print first; exit }
      }
    }'
}

# direct_merge_reason COMMAND
# Print "gh pr merge" when the command merges a pull request directly with
# gh, outside the merge queue. Turning auto-merge off is allowed. Print
# nothing otherwise. The caller decides whether the project has a queue.
# Both merge checks read the command's own words: the contents of quoted
# strings go first (code_only), so a printf that writes a body mentioning
# merge-queue.sh and five numbers is prose, not a merge.
direct_merge_reason() {
  split_commands "$(code_only "$1")" | awk '
    {
      line = $0
      gsub(/["'\'']/, "", line)
      n = split(line, t, /[ \t]+/)
      if (t[1] != "gh" || t[2] != "pr" || t[3] != "merge") next
      off = 0
      for (i = 4; i <= n; i++) if (t[i] == "--disable-auto") off = 1
      if (!off) { print "gh pr merge"; exit }
    }'
}

batch_merge_reason() {
  split_commands "$(code_only "$1")" | awk '
    {
      line = $0
      gsub(/["'\'']/, "", line)
      n = split(line, t, /[ \t]+/)
      found = 0
      for (i = 1; i <= n; i++) if (t[i] ~ /(^|[\/\\])merge-queue\.sh$/) found = 1
      if (!found) next
      prs = 0; flagged = 0
      for (i = 1; i <= n; i++) {
        if (t[i] == "--batch" || t[i] == "--serial" || t[i] == "--drain") flagged = 1
        else if (t[i] ~ /^[0-9]+$/) prs++
      }
      if (prs > 2 && !flagged) { print prs; exit }
    }'
}

# state_label_reason COMMAND
# Print "gh issue create" when the command creates an issue without a label
# that starts with "state:". Print nothing when the label is there, when the
# command opens the browser form instead, or when it is not an issue creation.
state_label_reason() {
  # gh's {owner} and {repo} placeholders are not shell groups
  split_commands "$(printf '%s' "$1" | sed 's/{owner}/OWNER/g; s/{repo}/REPO/g')" | awk '
    # The REST form: gh api ... repos/O/R/issues with a title and no
    # labels[]=state:... (a body from --input is not read; it passes).
    {
      line = $0; gsub(/["\x27]/, "", line)
      n = split(line, t, /[ \t]+/)
      if (t[1] == "gh" && t[2] == "api") {
        issues = 0; creates = 0; found = 0
        for (j = 3; j <= n; j++) {
          if (t[j] ~ /(^|\/)issues(\?.*)?$/) issues = 1
          if (t[j] ~ /^title=/) creates = 1
          if (t[j] == "--input" || t[j] ~ /^labels\[\]=[ \t]*state:/ || t[j] ~ /^labels=.*state:/) found = 1
        }
        if (issues && creates && !found) { print "gh api .../issues"; exit }
      }
    }
    {
      line = $0
      n = split(line, t, /[ \t]+/)
      if (t[1] != "gh" || t[2] != "issue" || t[3] != "create") next
      found = 0
      for (j = 4; j <= n; j++) if (t[j] == "--web" || t[j] == "-w") found = 1
      # A label value may hold spaces inside its quotes ("ci-red, state: ready"),
      # so look at the text after each --label up to the next option rather
      # than at one token. The label itself may be written state:ready or
      # state: ready.
      rest = line
      gsub(/["'\'']/, "", rest)
      while (match(rest, /(^|[ \t])(--label=|--label[ \t]+|-l[ \t]*)/)) {
        rest = substr(rest, RSTART + RLENGTH)
        value = rest
        if (match(value, /[ \t]-/)) value = substr(value, 1, RSTART - 1)
        if (value ~ /(^|,)[ \t]*state:/) found = 1
      }
      if (!found) { print "gh issue create"; exit }
    }'
}

# project_flag_reason COMMAND
# For a project whose state is a field on its GitHub Project rather than a
# label (.claude/issue-state.txt says "project"): print "gh issue create" when
# the command creates an issue without --project, so it lands on the board
# where its state is set. Print nothing otherwise, or for --web.
project_flag_reason() {
  split_commands "$1" | awk '
    {
      n = split($0, t, /[ 	]+/)
      if (t[1] != "gh" || t[2] != "issue" || t[3] != "create") next
      found = 0
      for (j = 4; j <= n; j++) if (t[j] == "--web" || t[j] == "-w" || t[j] == "--project" || t[j] == "-p" || t[j] ~ /^--project=/) found = 1
      if (!found) { print "gh issue create"; exit }
    }'
}

# gh_graphql_reason COMMAND
# Print the first gh command form in COMMAND that spends GraphQL points
# ("gh pr view", "gh issue create", "gh project item-list", "gh search
# issues", "gh api graphql"), or nothing. gh api on a REST path, gh run,
# gh auth and the rest are REST and cost nothing here.
gh_graphql_reason() {
  split_commands "$(printf '%s' "$1" | sed 's/{owner}/OWNER/g; s/{repo}/REPO/g')" | awk '
    {
      n = split($0, t, /[ \t]+/)
      for (i = 1; i < n; i++) if (t[i] == "gh") {
        s = t[i + 1]
        if (s == "issue" || s == "pr" || s == "project" || s == "search") { print "gh " s " " t[i + 2]; exit }
        if (s == "api" && t[i + 2] == "graphql") { print "gh api graphql"; exit }
      }
    }'
}

# The budget record: "graphql_left graphql_limit graphql_reset rest_left
# rest_limit rest_reset", tab-separated, as budget_fetch reads it from
# gh api rate_limit (an endpoint that is itself free). budget_read caches
# it in .scratch/gh-budget.txt for a minute, first field the epoch it was
# read, so seven agents and a queue share one reading.
BUDGET_JQ='[.resources.graphql.remaining, .resources.graphql.limit, .resources.graphql.reset, .resources.core.remaining, .resources.core.limit, .resources.core.reset] | @tsv'

# budget_cached CACHE_TEXT NOW [MAX_AGE]
# Print the record from a cache line "epoch<TAB>record" younger than
# MAX_AGE seconds (default 60); nothing when it is stale or empty.
budget_cached() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v max="${3:-60}" '
    NR == 1 && NF >= 7 && now - $1 >= 0 && now - $1 < max { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }'
}

# budget_line RECORD NOW [FLOOR]
# One line for the brief and the hook: "GraphQL 4,120 of 5,000 left, resets
# 09:19Z (in 23 min); REST 3,469 of 5,000 left." Under FLOOR GraphQL points
# (default 500) it ends with what to do; nothing for an empty record.
budget_line() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v floor="${3:-500}" '
    function commas(n,  s) { s = sprintf("%d", n); while (s ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]$|[0-9][0-9][0-9],/, ",&", s); return s }
    NR == 1 && NF >= 6 && $1 != "" {
      mins = int(($3 - now + 59) / 60); if (mins < 0) mins = 0
      printf "GraphQL %s of %s left, resets %s (in %d min); REST %s of %s left.", commas($1), commas($2), sprintf("%02d:%02dZ", int(($3 % 86400) / 3600), int(($3 % 3600) / 60)), mins, commas($4), commas($5)
      if ($1 + 0 < floor) printf " Low: use the REST forms (scripts/issue-open.sh, pr-open.sh, pr-checks.sh, gh api) and wait for the reset; never retry before it."
      printf "\n"
    }'
}

# budget_low RECORD [FLOOR]
# "yes" when fewer than FLOOR (default 500) GraphQL points are left, "no"
# otherwise or when the record is empty (an unknown budget blocks nothing).
budget_low() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v floor="${2:-500}" '
    NR == 1 && NF >= 6 && $1 != "" && $1 + 0 < floor { low = 1 } END { print (low ? "yes" : "no") }'
}

# budget_read ROOT
# The record, from the cache when it is younger than a minute, else from
# gh api rate_limit (bounded, free), which refreshes the cache. Empty when
# gh is absent or the call fails.
budget_read() {
  br_file="$1/.scratch/gh-budget.txt"; br_now=$(date +%s)
  br_rec=$(budget_cached "$(head -n 1 "$br_file" 2>/dev/null)" "$br_now")
  [ -n "$br_rec" ] && { printf '%s\n' "$br_rec"; return 0; }
  command -v gh >/dev/null 2>&1 || return 0
  br_rec=$(gh api rate_limit --jq "$BUDGET_JQ" 2>/dev/null | tr -d '\r') || br_rec=""
  [ -n "$br_rec" ] || return 0
  mkdir -p "$1/.scratch" 2>/dev/null && printf '%s\t%s\n' "$br_now" "$br_rec" > "$br_file" 2>/dev/null
  printf '%s\n' "$br_rec"
}
