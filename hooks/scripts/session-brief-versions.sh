# Sourced by session-brief.sh and session-brief-slow.sh: the plugin's
# versions, the pure parts. No network here; the released version is read
# in the background and cached.

# ver_lt A B: "yes" when version A is older than B (X.Y.Z), else "no".
ver_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) { print "yes"; exit } if (x[i] + 0 > y[i] + 0) { print "no"; exit } } print "no" }'
}

# plugin_lag_line INSTALLED RELEASED REPO UNRELEASED
# One plain line when the copy the drive runs is older than the released or
# the repository's version, naming the changes that wait on a release; and
# nothing when it is current or the installed version is not known.
plugin_lag_line() {
  pl_i=$1; pl_r=$2; pl_v=$3; pl_n=$4
  [ -n "$pl_i" ] || return 0
  pl_c=""
  if [ -n "$pl_r" ] && [ "$(ver_lt "$pl_i" "$pl_r")" = yes ]; then pl_c="$pl_r is released"; fi
  if [ -n "$pl_v" ] && [ "$pl_v" != "$pl_r" ] && [ "$(ver_lt "$pl_i" "$pl_v")" = yes ]; then
    pl_c="${pl_c:+$pl_c and }the repository is at $pl_v"
  fi
  [ -n "$pl_c" ] || return 0
  case "$pl_n" in ''|0|*[!0-9]*) ;; 1) pl_c="$pl_c and 1 change waits on a release" ;; *) pl_c="$pl_c and $pl_n changes wait on a release" ;; esac
  echo "Plugin: The drive runs $pl_i; $pl_c. Bring the installed copy up with plugin/scripts/release/update-installed.sh."
}

# plugin_extra_copy_line USER_VERSION PROJECT_VERSIONS
# PROJECT_VERSIONS is comma separated. Names a project-scoped copy older
# than the user-scoped one as a copy to remove; nothing otherwise.
plugin_extra_copy_line() {
  [ -n "$1" ] || return 0
  pe_old=""
  for pe_v in $(printf '%s' "$2" | tr ',' ' '); do
    if [ "$(ver_lt "$pe_v" "$1")" = yes ]; then pe_old="${pe_old:+$pe_old, }$pe_v"; fi
  done
  [ -n "$pe_old" ] || return 0
  echo "Plugin: a project-scoped copy at $pe_old is older than the user-scoped $1; remove it, since two copies make the version a guess."
}

# plugin_copies_read FILE KEY: "user=A project=B,C" from the installed
# plugins file's block for KEY (name@marketplace). Local data only.
plugin_copies_read() {
  [ -f "$1" ] || return 0
  awk -v key="\"$2\"" '
    index($0, key) { inb = 1; next }
    inb && /\]/ { inb = 0 }
    inb && /"scope"/ { s = $0; sub(/.*"scope"[^"]*"/, "", s); sub(/".*/, "", s) }
    inb && /"version"/ { v = $0; sub(/.*"version"[^"]*"/, "", v); sub(/".*/, "", v); if (s == "user") u = v; else if (s == "project") p = (p == "" ? v : p "," v) }
    END { if (u != "" || p != "") printf "user=%s project=%s\n", u, p }' "$1" | tr -d '\r'
}
