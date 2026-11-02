# Sourced by session-brief.sh and tests/run.sh: the helpers that keep the
# session brief inside its start limit. Pure functions, no network.

# cache_age STAMP NOW
# STAMP and NOW are epoch seconds. Print how old a cached brief line is, in
# words the brief puts beside it: "as of just now", "as of 12 min ago",
# "as of 3 h ago", "as of 2 days ago". Nothing for a missing or bad stamp.
# Arithmetic only, no process: the brief calls it once per cached line.
cache_age() {
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  ca_s=$(( $2 - $1 )); [ "$ca_s" -ge 0 ] || ca_s=0
  if [ "$ca_s" -lt 60 ]; then echo "as of just now"
  elif [ "$ca_s" -lt 3600 ]; then echo "as of $(( ca_s / 60 )) min ago"
  elif [ "$ca_s" -lt 172800 ]; then echo "as of $(( ca_s / 3600 )) h ago"
  else echo "as of $(( ca_s / 86400 )) days ago"; fi
}

# cache_due STAMP NOW [MAX]
# "yes" when the slow lines should be read again in the background: no stamp
# yet, a bad one, or one older than MAX seconds (default 300). "no" otherwise.
cache_due() {
  case "$1" in ''|*[!0-9]*) echo yes; return 0 ;; esac
  case "$2" in ''|*[!0-9]*) echo yes; return 0 ;; esac
  if [ $(( $2 - $1 )) -ge "${3:-300}" ]; then echo yes; else echo no; fi
}

# with_age TEXT AGE
# Each line of a cached TEXT with its AGE (from cache_age) after its label:
# "Deploys: main has..." becomes "Deploys (as of 4 min ago): main has...".
# A line with no "Label: " gets the age at its end. Nothing for no text.
with_age() {
  [ -n "$1" ] || return 0
  [ -n "$2" ] || { printf '%s\n' "$1"; return 0; }
  printf '%s\n' "$1" | tr -d '\r' | awk -v age="$2" '
    NF == 0 { next }
    match($0, /^[A-Z][A-Za-z ]*: /) { print substr($0, 1, RLENGTH - 2) " (" age "): " substr($0, RLENGTH + 1); next }
    { print $0 " (" age ")" }'
}

# owned_drift PATHS TEMPLATES
# PATHS is one path per line, relative to the working folder; TEMPLATES is
# the plugin's templates folder. Print "OLD<TAB>MISSING": how many of the
# paths differ from their template, by sync-lib's same_text rule (carriage
# returns and trailing newlines ignored), and how many are not here. One awk
# for every file, where a comparison per file once cost the brief half a
# minute in processes.
owned_drift() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v t="$2" '
    function slurp(f,   s, l, r) {
      s = ""
      while ((r = (getline l < f)) > 0) { gsub(/\r/, "", l); s = s l "\n" }
      close(f)
      if (r < 0 && s == "") return "\001missing"
      sub(/\n+$/, "", s)
      return s
    }
    NF {
      a = slurp($0)
      if (a == "\001missing") { missing++; next }
      b = slurp(t "/" $0)
      if (b == "\001missing") b = ""
      if (a != b) old++
    }
    END { printf "%d\t%d\n", old, missing }'
}
