#!/bin/sh
# Read an issue's labels without starting a process. The plan reads every issue
# of the board at least twice, and a command substitution and a pipe of small
# tools for each read was thousands of process starts on a board of a few dozen
# issues, on a machine where one start costs tens of milliseconds (#1794).
# Functions only; the plan sources it before the libraries that use it, which
# fall back to state_of_labels when it is not loaded.

# labels_facts LABELS
# LABELS is a comma separated list. Sets, in the shell's own variables:
# lf_state (as state_of_labels names it, "none" with no State label),
# lf_standing (yes for the drive issue's or the audit issue's label) and
# lf_red (yes for ci-red).
labels_facts() {
  lf_state=none; lf_standing=no; lf_red=no
  lf_tab=$(printf '	'); lf_ws=" $lf_tab"
  lf_old=$IFS; IFS=,; set -f
  for lf_l in $1; do
    IFS=$lf_old
    lf_l=${lf_l#"${lf_l%%[!$lf_ws]*}"}; lf_l=${lf_l%"${lf_l##*[!$lf_ws]}"}
    case "$lf_l" in
      [Ss][Tt][Aa][Tt][Ee]:*)
        if [ "$lf_state" = none ]; then
          lf_v=${lf_l#*:}; lf_v=${lf_v#"${lf_v%%[!$lf_ws]*}"}
          lf_state=""
          while :; do
            case "$lf_v" in
              *[[:upper:]]*) lf_v=$(printf '%s' "$lf_v" | tr 'A-Z' 'a-z') ;;
              *" "*|*"$lf_tab"*) lf_state=$lf_state${lf_v%%[$lf_ws]*}-; lf_v=${lf_v#*[$lf_ws]}; lf_v=${lf_v#"${lf_v%%[!$lf_ws]*}"} ;;
              *) lf_state=$lf_state$lf_v; break ;;
            esac
          done
        fi ;;
      [Dd][Rr][Ii][Vv][Ee]|[Aa][Uu][Dd][Ii][Tt]) lf_standing=yes ;;
      ci-red) lf_red=yes ;;
    esac
    IFS=,
  done
  set +f; IFS=$lf_old
}
