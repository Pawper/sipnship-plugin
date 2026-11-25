#!/bin/sh
# Every package the batch checkout needs: a lockfile's hash, linking from
# the main checkout's node_modules when it already has them and an install
# is known to have finished there, installing when it does not. Sourced by
# scripts/ci/merge-queue.sh; functions only.

# ensure_modules: every package in the batch checkout has the packages its
# own lockfile names. Where the lockfile is the main checkout's, its
# node_modules are linked (a junction on Windows, a symlink elsewhere), so
# nothing is installed twice. Where it differs (main moved a dependency or
# a workspace package, or a member changed one), the link is removed
# (only the link: never the files behind it) and the project's install
# runs there, QUEUE_INSTALL_COMMAND or "npm ci". A workspace root (see ensure_workspace) is one unit. A stale link once made a
# green main type-check red "before any merge".
mod_hash() { [ -f "$1" ] && git hash-object "$1" 2>/dev/null || echo none; }
# pkg_hash DIR PACKAGE_DIR: the lockfile's hash plus the tree hash of every
# "file:" dependency of DIR's package.json at that checkout's HEAD, so a
# repack of packages/core that lands on main without touching the lockfile
# still counts as a change. A batch once refused to start with "main is red"
# on a type error main did not have: its node_modules held the old copy.
pkg_hash() {
  ph_lock=$(mod_hash "$1/$2/package-lock.json")
  ph_trees=$(for ph_p in $(file_deps "$(cat "$1/$2/package.json" 2>/dev/null)"); do
    git -C "$1" rev-parse -q --verify "HEAD:$2/$ph_p" 2>/dev/null || echo none
  done | paste -sd, -)
  printf '%s%s\n' "$ph_lock" "${ph_trees:+,$ph_trees}"
}
is_link() { [ -e "$1" ] && [ "$(cd -P "$1" 2>/dev/null && pwd -P)" != "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1")" ]; }
unlink_dir() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) cmd //c rmdir "$(cygpath -w "$1")" >/dev/null 2>&1 ;;
    *) unlink "$1" 2>/dev/null ;;
  esac
}
# link_dir TARGET LINK. Git Bash rewrites "/J" as a path unless told not
# to, and mklink then failed with "Invalid switch", quietly.
link_dir() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' cmd /c mklink /J "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null 2>&1 ;;
    *) ln -s "$1" "$2" 2>/dev/null ;;
  esac
}
install_here() { # DIR HASH
  echo "Installing packages in $1 (its lockfile or a file: package is not what the installed packages came from)."
  if (cd "$1" && sh -c "${QUEUE_INSTALL_COMMAND:-npm ci --no-audit --no-fund}") >/dev/null 2>"$flaky_dir/install.err"; then
    printf '%s\n' "$2" > "$1/node_modules/.queue-lock-hash" 2>/dev/null || true
  else
    echo "  the install failed: $(tail -n 1 "$flaky_dir/install.err" 2>/dev/null)"
    echo "$1: the install failed" >> "$flaky_dir/modules.stale"
  fi
}

# A workspace is one unit: the root lockfile plus each member's package.json
# is the hash, the install runs once from the root, and the root's and each
# member's node_modules are linked when the hash is main's.
ensure_workspace() { # KIND
  ew_hash=$(workspace_hash "$wt" "$1")
  ew_main=$(workspace_hash "$main_dir" "$1")
  ew_dirs=". $(workspace_members "$wt" | tr '\n' ' ')"
  ew_ok=1
  # Linking trusts the main checkout's own node_modules only when an install
  # is known to have finished there (install_finished, #2768): one left
  # half-built or emptied by an interrupted install once read main as red
  # in the batch checkout, because only the lockfile's hash was checked,
  # never whether the install behind it had completed.
  ew_main_ok=$(install_finished "$main_dir" "$ew_main")
  for ew_d in $ew_dirs; do
    ew_nm="$wt/$ew_d/node_modules"
    if is_link "$ew_nm"; then
      [ "$ew_hash" = "$ew_main" ] && [ "$ew_main_ok" = yes ] && continue
      unlink_dir "$ew_nm" || { echo "  could not remove the link at $ew_nm; the type-check may read stale packages"; echo "$ew_nm: the link to the main checkout's packages could not be removed" >> "$flaky_dir/modules.stale"; }
    fi
  done
  if [ -d "$wt/node_modules" ] && ! is_link "$wt/node_modules"; then
    [ "$(cat "$wt/node_modules/.queue-lock-hash" 2>/dev/null)" = "$ew_hash" ] && return 0
    ew_ok=0
  fi
  if [ "$ew_ok" = 1 ] && [ "$ew_hash" = "$ew_main" ] && [ -d "$main_dir/node_modules" ]; then
    if [ "$ew_main_ok" != yes ]; then
      echo "The main checkout's packages at $main_dir are not known to have finished installing (no install record in its node_modules); installing afresh in the batch instead of linking them."
    else
      for ew_d in $ew_dirs; do
        [ -d "$main_dir/$ew_d/node_modules" ] || continue
        [ -e "$wt/$ew_d/node_modules" ] && continue
        link_dir "$main_dir/$ew_d/node_modules" "$wt/$ew_d/node_modules" || echo "  could not link $wt/$ew_d/node_modules; the type-check may not find its packages"
      done
      return 0
    fi
  fi
  ew_cmd=${QUEUE_INSTALL_COMMAND:-$(workspace_install_command "$wt" "$1")}
  QUEUE_INSTALL_COMMAND=$ew_cmd install_here "$wt" "$ew_hash"
}
ensure_modules() {
  em_kind=$(workspace_kind "$wt")
  if [ -n "$em_kind" ]; then rm -f "$flaky_dir/modules.stale" 2>/dev/null; ensure_workspace "$em_kind"; return 0; fi
  rm -f "$flaky_dir/modules.stale" 2>/dev/null
  git -C "$wt" ls-files -- package.json '*/package.json' 2>/dev/null | sed 's#/package\.json$##; s#^package\.json$#.#' | while IFS= read -r d; do
    em_nm="$wt/$d/node_modules"
    em_lock=$(pkg_hash "$wt" "$d")
    em_main=$(pkg_hash "$main_dir" "$d")
    # Linked from main only when an install is known to have finished there
    # (install_finished, #2768); the worktree's own node_modules is reused by
    # its exact marker match below, which already answers both at once.
    em_main_ok=$(install_finished "$main_dir/$d" "$em_main")
    if is_link "$em_nm"; then
      if [ "$em_lock" = "$em_main" ] && [ "$em_main_ok" = yes ]; then continue; fi
      unlink_dir "$em_nm" || { echo "  could not remove the link at $em_nm; the type-check may read stale packages"; echo "$em_nm: the link to the main checkout's packages could not be removed" >> "$flaky_dir/modules.stale"; continue; }
    elif [ -d "$em_nm" ]; then
      if [ "$(cat "$em_nm/.queue-lock-hash" 2>/dev/null)" = "$em_lock" ]; then continue; fi
      [ -f "$wt/$d/package-lock.json" ] || continue
      install_here "$wt/$d" "$em_lock"; continue
    fi
    mkdir -p "$wt/$d"
    if [ "$em_lock" = "$em_main" ] && [ -d "$main_dir/$d/node_modules" ] && [ "$em_main_ok" = yes ]; then
      link_dir "$main_dir/$d/node_modules" "$em_nm" || echo "  could not link $em_nm; the type-check may not find its packages"
    elif [ -f "$wt/$d/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
      if [ "$em_lock" = "$em_main" ] && [ -d "$main_dir/$d/node_modules" ]; then echo "  main's packages at $main_dir/$d are not known to have finished installing; installing afresh in $wt/$d instead of linking them."; fi
      install_here "$wt/$d" "$em_lock"
    fi
  done
}
