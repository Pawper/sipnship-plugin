# Sourced by sync-lib.sh: how the sync reads which repository scripts a
# workflow or a script needs. Split out of sync-lib.sh; nothing here changed.

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

# template_deps TPL PATH...
# For each PATH (relative to the templates folder TPL) that is a workflow
# or a .sh script there, one line "PATH<TAB>DEPS": a workflow's
# sourced_scripts, a script's loaded_scripts then its here_scripts, space
# separated, the same as those three give. One awk for every file: a
# process per file made the sync take minutes on Windows.
template_deps() {
  td_tpl=$1; shift
  td_files=""
  for td_p in "$@"; do
    case "$td_p" in .github/workflows/*.yml|*.sh) if [ -f "$td_tpl/$td_p" ]; then td_files="$td_files $td_p"; fi ;; esac
  done
  [ -n "$td_files" ] || return 0
  (cd "$td_tpl" && awk '
    function flush(   i, out) {
      if (cur == "") return
      out = ""
      if (cur ~ /\.yml$/) { for (i = 1; i <= ns; i++) if (!(so[i] in guarded)) out = out (out == "" ? "" : " ") so[i] }
      else {
        for (i = 1; i <= nl; i++) out = out (out == "" ? "" : " ") lo[i]
        for (i = 1; i <= nh; i++) out = out (out == "" ? "" : " ") ho[i]
      }
      printf "%s\t%s\n", cur, out
    }
    FNR == 1 {
      flush(); cur = FILENAME; ns = nl = nh = 0
      split("", guarded); split("", sseen); split("", lseen); split("", hseen)
      dir = cur; if (dir ~ /\//) sub(/\/[^\/]*$/, "", dir); else dir = "."
    }
    {
      line0 = $0; gsub(/\r/, "", line0)
      if (cur ~ /\.yml$/) {
        line = line0
        while (match(line, /-f[ \t]+scripts\/[A-Za-z0-9_.\/-]+/)) {
          g = substr(line, RSTART, RLENGTH); sub(/^-f[ \t]+/, "", g); guarded[g] = 1
          line = substr(line, RSTART + RLENGTH)
        }
        line = line0
        while (match(line, /(^|[ \t;&|(])(\.|sh)[ \t]+scripts\/[A-Za-z0-9_.\/-]+/)) {
          s = substr(line, RSTART, RLENGTH); sub(/^.*(\.|sh)[ \t]+/, "", s); sub(/\.+$/, "", s)
          if (!(s in sseen)) { sseen[s] = 1; so[++ns] = s }
          line = substr(line, RSTART + RLENGTH)
        }
      } else {
        if (line0 ~ /^[ \t]*\.[ \t]+scripts\//) {
          s = line0; sub(/^[ \t]*\.[ \t]+/, "", s); sub(/[ \t;].*$/, "", s); sub(/\.+$/, "", s)
          if (!(s in lseen)) { lseen[s] = 1; lo[++nl] = s }
        }
        line = line0
        while (match(line, /\$here\/[A-Za-z0-9_.-]+/)) {
          s = substr(line, RSTART + 6, RLENGTH - 6); sub(/\.+$/, "", s)
          if (!(s in hseen)) { hseen[s] = 1; ho[++nh] = dir "/" s }
          line = substr(line, RSTART + RLENGTH)
        }
      }
    }
    END { flush() }' $td_files)
}
