#!/bin/sh
# Pure helpers for the batch checkout: file: dependencies, generated files,
# releases, workspaces, the wait log and the known template hashes. Loaded by
# scripts/ci/batch-lib.sh.

# file_deps PACKAGE_JSON
# The paths of the "file:" dependencies in a package.json (dependencies,
# devDependencies, optionalDependencies), one a line, as written after
# "file:". A package installed by copy from such a path goes stale when
# the path changes on main while the lockfile does not; the queue hashes
# these trees as well as the lockfile.
file_deps() {
  printf '%s\n' "$1" | tr -d '\r' | tr ',{}' '\n\n\n' | sed -n 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*"file:\([^"]*\)".*/\1/p'
}

# generated_globs TEXT / rebuild_command TEXT
# TEXT is scripts/ci/generated-paths.txt: one shell glob per line naming
# checked-in build output, and one line "rebuild: COMMAND". Print the globs,
# or the command.
generated_globs() { printf '%s\n' "$1" | tr -d '\r' | sed 's/#.*//; /^[[:space:]]*rebuild:/d; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'; }
rebuild_command() { printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[[:space:]]*rebuild:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | head -n 1; }

# generated_only FILES TEXT
# "yes" when FILES (one path per line, at least one) all match a glob of
# TEXT'\''s generated paths; "no" otherwise, and when the list is empty.
# Two pull requests that each commit their own rebuild of a shared package
# conflict on it even when their sources do not; the queue takes either
# side and rebuilds instead of dropping one.
generated_only() {
  go_globs=$(generated_globs "$2")
  if [ -z "$go_globs" ]; then echo no; return 0; fi
  set -f
  go_any=no; go_all=yes
  for go_f in $(printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | sed '/^[[:space:]]*$/d'); do
    go_any=yes; go_hit=no
    for go_pat in $go_globs; do case "$go_f" in $go_pat) go_hit=yes; break ;; esac; done
    if [ "$go_hit" = no ]; then go_all=no; fi
  done
  set +f
  if [ "$go_any" = yes ] && [ "$go_all" = yes ]; then echo yes; else echo no; fi
}

# release_on DEPLOY_JSON: "ask" or "deploy" (the default), from "releaseOn"
# in .claude/deploy.json. "ask": the queue never starts the listed releases
# after a landing; merge-queue.sh --release starts each once, on request.
release_on() {
  ro=$(printf '%s' "$1" | tr -d '\r\n' | sed -n 's/.*"releaseOn"[ \t]*:[ \t]*"\([a-z]*\)".*/\1/p')
  case "$ro" in ask) echo ask ;; *) echo deploy ;; esac
}

# release_hold STATE ON WHY
# Why a release workflow is not started, or nothing to start it. STATE is
# its state from the API (active, disabled_manually, ...); ON is release_on;
# WHY is "landing" (after a merge) or "ask" (merge-queue.sh --release).
release_hold() {
  case "$1" in disabled*) echo "(it is turned off; a turned-off release is held on purpose)"; return 0 ;; esac
  if [ "$2" = ask ] && [ "$3" = landing ]; then echo "(releaseOn is ask; merge-queue.sh --release starts it)"; fi
}

# workspace_kind DIR
# "pnpm", "npm" or "yarn" when DIR is a workspace root (a pnpm-workspace.yaml,
# or a package.json with a "workspaces" field, the tool named by its
# lockfile), else nothing: a project of separate packages is not one.
workspace_kind() {
  if [ -f "$1/pnpm-workspace.yaml" ]; then echo pnpm
  elif [ -f "$1/package.json" ] && grep -q '"workspaces"' "$1/package.json" 2>/dev/null; then
    if [ -f "$1/yarn.lock" ] && [ ! -f "$1/package-lock.json" ]; then echo yarn; else echo npm; fi
  fi
}

# workspace_lockfile KIND: the root lockfile's name.
workspace_lockfile() {
  case "$1" in pnpm) echo pnpm-lock.yaml ;; yarn) echo yarn.lock ;; *) echo package-lock.json ;; esac
}

# workspace_globs DIR: the member globs, one a line ("packages/*").
workspace_globs() {
  if [ -f "$1/pnpm-workspace.yaml" ]; then
    tr -d '\r' < "$1/pnpm-workspace.yaml" | sed -n "s/^[[:space:]]*-[[:space:]]*['\"]\{0,1\}\([^'\"#]*[^'\"# ]\)['\"]\{0,1\}.*/\1/p" | grep -v '^!'
  else
    tr -d '\r' < "$1/package.json" 2>/dev/null | tr '\n' ' ' | sed -n 's/.*"workspaces"[[:space:]]*:[[:space:]]*\({[^}]*"packages"[[:space:]]*:[[:space:]]*\)\{0,1\}\[\([^]]*\)\].*/\2/p' | tr ',' '\n' | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
  fi
}

# workspace_members DIR: the member folders (relative, sorted) that a glob
# names and that hold a package.json. Only "folder/*" and plain folders.
workspace_members() {
  { workspace_globs "$1"; echo; } | while IFS= read -r wm_g; do
    [ -n "$wm_g" ] || continue
    wm_g=${wm_g#./}; wm_g=${wm_g%/}
    case "$wm_g" in
      */\*)
        for wm_d in "$1/${wm_g%/\*}"/*/; do
          [ -f "${wm_d}package.json" ] || continue
          wm_d=${wm_d%/}; echo "${wm_d#"$1"/}"
        done ;;
      *\**) ;;
      *) [ -f "$1/$wm_g/package.json" ] && echo "$wm_g" ;;
    esac
  done | sort -u
}

# workspace_hash DIR KIND: the root lockfile's hash plus each member's
# package.json hash, one string; changes when either does.
workspace_hash() {
  wh_f="$1/$(workspace_lockfile "$2")"
  wh_h=$( [ -f "$wh_f" ] && git hash-object "$wh_f" 2>/dev/null || echo none )
  for wh_m in $(workspace_members "$1"); do
    wh_h="$wh_h,$(git hash-object "$1/$wh_m/package.json" 2>/dev/null || echo none)"
  done
  echo "$wh_h"
}

# workspace_install_command DIR KIND: the install, run once from the root.
# pnpm comes from the path, then corepack, then npx at the major the
# lockfile's header names.
workspace_install_command() {
  case "$2" in
    pnpm)
      if command -v pnpm >/dev/null 2>&1; then echo "pnpm install --frozen-lockfile"
      elif command -v corepack >/dev/null 2>&1; then echo "corepack pnpm install --frozen-lockfile"
      else
        wi_v=$(sed -n "s/^lockfileVersion:[[:space:]]*['\"]\{0,1\}\([0-9]*\).*/\1/p" "$1/pnpm-lock.yaml" 2>/dev/null | head -n 1)
        case "$wi_v" in 9) wi_p=9 ;; 6) wi_p=8 ;; 5) wi_p=7 ;; *) wi_p=latest ;; esac
        echo "npx --yes pnpm@$wi_p install --frozen-lockfile"
      fi ;;
    yarn) echo "yarn install --immutable" ;;
    *) echo "npm ci --no-audit --no-fund" ;;
  esac
}

# waits_append FILE NOW JOB BUSY TOTAL MINUTES
# Keep one row per wait the queue saw for a runner, in FILE (the project's
# .scratch/queue/waits.tsv): epoch, local time, which job, runners busy,
# runners in all, minutes waited; newest last. Rows older than thirty days
# are dropped on each write, so the log stays small. Local only.
waits_append() {
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 0
  wa_when=$(date -d "@$2" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$2" '+%Y-%m-%d %H:%M' 2>/dev/null || echo -)
  wa_job=$(printf '%s' "$3" | tr '\t\r\n' '   ')
  { cat "$1" 2>/dev/null; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$wa_when" "${wa_job:-a job}" "${4:-0}" "${5:-0}" "${6:-0}"; } \
    | awk -F'\t' -v cut=$(( $2 - 30 * 86400 )) 'NF >= 6 && $1 + 0 >= cut' > "$1.new" 2>/dev/null && mv "$1.new" "$1"
}

# known_refresh DIR FROM: after a merge in the checkout at DIR (FROM is the
# commit before the merge), when the merge changed a plugin-owned template
# (anything under plugin/templates/, which holds every path OWNED.txt
# lists), add the versions FROM..HEAD made to the known-hashes list with
# the plugin's own script (seconds, never all of history) and commit it on the branch when it differs from the committed one. Two pull
# requests that change one template, merged together, make a version
# neither hashed; the list is derived, never refreshed by hand. Prints one
# line when it committed, nothing otherwise. A checkout without the
# plugin's sources is left alone.
known_refresh() {
  kr_dir=$1
  [ -f "$kr_dir/plugin/scripts/sync/known-hashes.sh" ] && [ -f "$kr_dir/plugin/templates/OWNED.txt" ] || return 0
  kr_n=$(git -C "$kr_dir" diff --name-only "$2" HEAD -- plugin/templates/ 2>/dev/null | grep -vx 'plugin/templates/KNOWN.txt' | grep -c .) || true
  [ "${kr_n:-0}" -gt 0 ] || return 0
  # The script reads the committed list, so it writes outside the checkout first.
  kr_new=$(mktemp) || return 0
  (cd "$kr_dir" && sh plugin/scripts/sync/known-hashes.sh "$2..HEAD") > "$kr_new" 2>/dev/null || return 0
  mv "$kr_new" "$kr_dir/plugin/templates/KNOWN.txt" || return 0
  git -C "$kr_dir" diff --quiet -- plugin/templates/KNOWN.txt && return 0
  git -C "$kr_dir" add plugin/templates/KNOWN.txt >/dev/null 2>&1 || return 0
  git -C "$kr_dir" commit -q -m "Refresh the known template hashes" >/dev/null 2>&1 || return 0
  echo "refreshed the known template hashes ($kr_n template(s) changed in the merge)"
}
