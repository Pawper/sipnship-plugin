# The known template hashes: which released versions of the plugin's owned
# files a project's copy matches (templates/KNOWN.txt). Sourced after
# sync-lib.sh, whose owned_paths, unfill_text and unfill_comments it uses.

# norm_hash TEXT
# A content hash of TEXT that ignores carriage returns and trailing
# newlines, the same way same_text does, so a Windows checkout of a file
# hashes as its template does.
norm_hash() {
  printf '%s\n' "$1" | tr -d '\r' | git hash-object --stdin
}

# known_match KNOWN PATH TEXT RUNS_ON RUN_SHELL
# "yes" when TEXT is a released version of the plugin file PATH: its hash,
# as written or with the project's runner and shell put back to their
# placeholders, is a "PATH HASH" line of KNOWN (templates/KNOWN.txt).
known_match() {
  # The three readings are tried one after another and the first line that
  # matches ends it: a plugin file as it stands (most of them) costs one
  # hash, and each lookup is the shell's own, not a process.
  km_a=$(norm_hash "$3")
  km_in "$1" "$2 $km_a" && { echo yes; return 0; }
  km_b=$(norm_hash "$(unfill_text "$3" "$4" "$5")")
  km_in "$1" "$2 $km_b" && { echo yes; return 0; }
  km_c=$(norm_hash "$(unfill_text "$(unfill_comments "$(unfill_comments "$3" RUNS_ON "$4")" RUN_SHELL "$5")" "$4" "$5")")
  km_in "$1" "$2 $km_c" && { echo yes; return 0; }
  echo no
}
# km_in LIST LINE: whether LINE is one whole line of LIST, as grep -x says.
km_in() {
  case "
$1
" in *"
$2
"*) return 0 ;; esac
  return 1
}

# known_missing TEMPLATES_DIR
# The owned templates under TEMPLATES_DIR whose current content is not a
# "PATH HASH" line of its KNOWN.txt, one per line, indented. The suite and
# scripts/ci/known-hashes-check.sh (so the local checks and CI) ask this one
# question.
known_missing() {
  km_list=$(tr -d '\r' < "$1/KNOWN.txt")
  for km_p in $(owned_paths "$(cat "$1/OWNED.txt")"); do
    [ -f "$1/$km_p" ] || continue
    printf '%s\n' "$km_list" | grep -qxF "$km_p $(norm_hash "$(cat "$1/$km_p")")" || printf '  %s\n' "$km_p"
  done
}

# known_missing_words MISSING
# The one wording for a stale list, with the one command that regenerates it,
# written as bump.sh runs it. Nothing for an empty MISSING.
known_missing_words() {
  [ -n "$1" ] || return 0
  printf '%s\n' "Every current template must be in KNOWN.txt (the list of known template hashes), and these are not:" "$1" \
    "Run scripts/sync/known-hashes.sh before a release, and commit plugin/templates/KNOWN.txt:" \
    "  sh plugin/scripts/sync/known-hashes.sh origin/main..HEAD > plugin/templates/KNOWN.txt.new && cat plugin/templates/KNOWN.txt.new > plugin/templates/KNOWN.txt && rm -f plugin/templates/KNOWN.txt.new"
}
