#!/bin/sh
# Pure helpers for the runner doctor. Text in, "ok" or "warn" out.

# bash_verdict PATH
# "warn" when there is no bash or it is Windows' WSL launcher in System32,
# "ok" otherwise.
bash_verdict() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    '') echo warn ;;
    *system32*) echo warn ;;
    *) echo ok ;;
  esac
}

# tool_on_machine_path TOOL_PATH MACHINE_PATH
# "ok" when the folder of TOOL_PATH appears in MACHINE_PATH (the PATH the
# runner service sees), comparing slashes and case loosely; "warn" otherwise.
tool_on_machine_path() {
  tp_dir=$(printf '%s' "$1" | tr '\\' '/' | tr 'A-Z' 'a-z' | sed 's#/[^/]*$##; s#^/\([a-z]\)/#\1:/#; s#\.exe$##')
  # A machine PATH entry may be written with %SystemRoot% or a trailing slash.
  printf '%s' "$2" | tr '\\' '/' | tr 'A-Z' 'a-z' | tr ';' '\n' | sed 's#/$##; s#%systemroot%#c:/windows#' | grep -qxF "$tp_dir" && echo ok || echo warn
}

# policy_verdict LIST
# LIST is "Scope=Policy" pairs. "warn" when the machine or local-machine
# policy is Restricted or AllSigned, "ok" otherwise.
policy_verdict() {
  printf '%s' "$1" | tr ' ' '\n' | awk -F= '
    tolower($1) == "localmachine" || tolower($1) == "machinepolicy" { if (tolower($2) == "restricted" || tolower($2) == "allsigned") bad = 1 }
    END { print bad ? "warn" : "ok" }'
}

# exepath_verdict VALUE
# VALUE is NoDefaultCurrentDirectoryInExePath as this shell sees it. Git
# Bash sets it to 1. A runner started from such a shell, and every job it
# launches, inherits it, and then cmd will not run a program from the
# current folder by its bare name: `gradlew.bat` fails as "not recognized"
# while `if exist gradlew.bat` still passes. "warn" when it is set.
exepath_verdict() {
  if [ -n "$1" ]; then echo warn; else echo ok; fi
}
