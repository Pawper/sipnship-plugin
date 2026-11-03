#!/bin/sh
# Batch mode: the integration branch built in its own worktree, the
# packages linked or installed there, the type-check, the one full run, and
# the merge. Sourced by scripts/ci/merge-queue.sh; functions only.

# The batch as it changes shape, for publish-state.sh (spec 001): one line
# per fact in batch.state ("stage\tS", "branch\tB", "pr\tN", "run\tID",
# "member\tN\tTITLE\tSTATE", "dropped\tN\tTITLE\tWHY"); later lines win.
# batch_note writes one; batch_moment publishes it, at most once a minute,
# and a moment held back by that minute goes with the next look.
batch_note() {
  bn_line=""
  for bn_f in "$@"; do bn_line="$bn_line${bn_line:+	}$(printf '%s' "$bn_f" | tr '\t\r\n' '   ')"; done
  printf '%s\n' "$bn_line" >> "$flaky_dir/batch.state" 2>/dev/null || true
}
batch_moment() { batch_note stage "$1"; publish_now batch; }
# batch_out PR WHAT WHY: a member that does not go in, said and published.
batch_out() {
  batch_line "$1" "$2" "$3"
  batch_note dropped "$1" "$(pr_field "$1" 3)" "$2${3:+: $3}"
  publish_now batch
}

# typecheck_ok PATHS [DIR]: the type-check, run once in each package the
# change touches (the nearest folder above each changed file with a
# tsconfig.json), or once from the root when QUEUE_TYPECHECK_COMMAND names
# the project's own command. DIR is the checkout to run in (default here).
# Returns non-zero on the first red package, with its output in
# .scratch/queue/typecheck.err so the caller can name the first error.
typecheck_ok() {
  tc_root=${2:-.}
  : > "$flaky_dir/typecheck.err"
  if [ -n "$QUEUE_TYPECHECK_COMMAND" ] || [ -z "$ts_roots" ]; then (cd "$tc_root" && sh -c "$typecheck") >"$flaky_dir/typecheck.err" 2>&1; return $?; fi
  tc_dirs=$(printf '%s\n' "$1" | while IFS= read -r tc_f; do if [ -n "$tc_f" ]; then nearest_root "$tc_f" "$ts_roots"; fi; done | sort -u)
  for tc_d in $tc_dirs; do
    [ -f "$tc_root/$tc_d/tsconfig.json" ] || continue
    (cd "$tc_root/$tc_d" && sh -c "$typecheck") >"$flaky_dir/typecheck.err" 2>&1 || return 1
  done
  return 0
}

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
  for ew_d in $ew_dirs; do
    ew_nm="$wt/$ew_d/node_modules"
    if is_link "$ew_nm"; then
      [ "$ew_hash" = "$ew_main" ] && continue
      unlink_dir "$ew_nm" || { echo "  could not remove the link at $ew_nm; the type-check may read stale packages"; echo "$ew_nm: the link to the main checkout's packages could not be removed" >> "$flaky_dir/modules.stale"; }
    fi
  done
  if [ -d "$wt/node_modules" ] && ! is_link "$wt/node_modules"; then
    [ "$(cat "$wt/node_modules/.queue-lock-hash" 2>/dev/null)" = "$ew_hash" ] && return 0
    ew_ok=0
  fi
  if [ "$ew_ok" = 1 ] && [ "$ew_hash" = "$ew_main" ] && [ -d "$main_dir/node_modules" ]; then
    for ew_d in $ew_dirs; do
      [ -d "$main_dir/$ew_d/node_modules" ] || continue
      [ -e "$wt/$ew_d/node_modules" ] && continue
      link_dir "$main_dir/$ew_d/node_modules" "$wt/$ew_d/node_modules" || echo "  could not link $wt/$ew_d/node_modules; the type-check may not find its packages"
    done
    return 0
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
    if is_link "$em_nm"; then
      if [ "$em_lock" = "$em_main" ]; then continue; fi
      unlink_dir "$em_nm" || { echo "  could not remove the link at $em_nm; the type-check may read stale packages"; echo "$em_nm: the link to the main checkout's packages could not be removed" >> "$flaky_dir/modules.stale"; continue; }
    elif [ -d "$em_nm" ]; then
      if [ "$(cat "$em_nm/.queue-lock-hash" 2>/dev/null)" = "$em_lock" ]; then continue; fi
      [ -f "$wt/$d/package-lock.json" ] || continue
      install_here "$wt/$d" "$em_lock"; continue
    fi
    mkdir -p "$wt/$d"
    if [ "$em_lock" = "$em_main" ] && [ -d "$main_dir/$d/node_modules" ]; then
      link_dir "$main_dir/$d/node_modules" "$em_nm" || echo "  could not link $em_nm; the type-check may not find its packages"
    elif [ -f "$wt/$d/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
      install_here "$wt/$d" "$em_lock"
    fi
  done
}

# An earlier batch pull request still open is superseded by this one; close
# it with a comment rather than leave it next to the new one.
close_pr() { # NUMBER REASON
  gh_write api -X POST "repos/{owner}/{repo}/issues/$1/comments" -f body="$2" >/dev/null 2>&1 || true
  gh_write api -X PATCH "repos/{owner}/{repo}/pulls/$1" -f state=closed >/dev/null 2>&1 && echo "closed batch PR #$1: $2"
}

# queue_batch: the --batch mode, run by merge-queue.sh once the lock is taken.
queue_batch() {
b_begin=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
# Batch mode. The batch is built in its own worktree, never in the main
# checkout, so a person working there is not switched onto the batch
# branch under their feet. QUEUE_WORKTREE names the folder; the default is
# a sibling of the repository called <repo>-wt-batch, which is reused from
# one batch to the next. Each package's node_modules is linked from the
# main checkout when the worktree has none, so nothing is installed twice.
if ! fetch_base; then
  # Not tried: the drain takes these again next round rather than calling
  # them done.
  printf '%s\n' $prs >> "$flaky_dir/untried" 2>/dev/null || true
  echo "Nothing merged this round: main could not be fetched. These are tried again:$(printf ' #%s' $prs)"
  exit 1
fi
day=$(date +%Y-%m-%d)  # the owner's local day, like every date in the repository
n=1
stamp=$(date +%H%M%S)
branch=$(batch_branch_name "$day" "$n" "$stamp")
while git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; do
  n=$((n + 1)); branch=$(batch_branch_name "$day" "$n" "$stamp")
done
# The main checkout is the first worktree git lists, whatever folder the
# queue was started from; its node_modules are the ones to link, and the
# batch worktree is named after it.
main_dir=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' | tr -d '\r')
[ -n "$main_dir" ] && [ -d "$main_dir" ] || main_dir=$(pwd)
wt=${QUEUE_WORKTREE:-"$(cd "$main_dir/.." && pwd)/$(basename "$main_dir")-wt-batch"}
# A folder git no longer knows is moved aside, never deleted, and made afresh.
batch_folder_repair "$wt" "$(date +%Y-%m-%d-%H%M)" | while IFS= read -r bf_l; do say "$bf_l"; done
if git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$wt" checkout -q -B "$branch" "origin/$base"
elif ! git worktree add -q -B "$branch" "$wt" "origin/$base"; then
  printf '%s\n' "the batch folder could not be made" > "$flaky_dir/batch.why" 2>/dev/null || true
  echo "Nothing merged: the batch folder $wt could not be made."
  exit 1
fi
ensure_modules
echo "batch branch $branch in $wt from origin/$base"

# The base is checked before anything is merged. A red base (packages not
# installed, generated types stale) made every pull request look red
# after its merge, and all of them were dropped for a fault none of them
# had. Nothing is dropped for that; the batch stops and says what is red.
if [ -n "$typecheck" ] && ! typecheck_ok "$(git -C "$wt" ls-files)" "$wt"; then
  tc_first=$(grep -v '^[[:space:]]*$' "$flaky_dir/typecheck.err" 2>/dev/null | head -n 1 | tr -d '\r')
  case "$tc_first" in
    *"not the tsc command"*|*"Cannot find module"*|*"ENOENT"*|*"command not found"*)
      echo "The type-check could not run in $wt (packages are not installed there: $tc_first). That is not a red base." ;;
    *)
      if [ -s "$flaky_dir/modules.stale" ]; then
        echo "The checkout's installed packages are older than origin/$base ($(paste -sd';' "$flaky_dir/modules.stale")), so this type error is the checkout's, not main's: $tc_first"
      else
        echo "origin/$base is red here before any merge: $tc_first"
      fi ;;
  esac
  echo "Nothing was dropped for it. Fix the checkout at $wt (install the packages, regenerate the types) and run the batch again."
  exit 1
fi

carried=""
refs=""
dropped=""
good=$(git -C "$wt" rev-parse HEAD)

# Which pull requests go in. The earliest always does; of the rest, the
# largest set that conflicts with nothing already in, read pair by pair
# with git merge-tree, which merges in memory and touches no files. A
# pull request left out conflicts with one that lands now, so it will
# conflict with main: its owner is told now, with the files.
for pr in $prs; do fetch_pr_head "$pr" "$wt" >/dev/null || true; done
# The owner console reads this line to show which pull requests are being
# test-merged; it is cleared when the pairing ends.
printf 'checking %s\n' "$(printf '%s ' $prs | sed 's/ $//')" > "$flaky_dir/now" 2>/dev/null || true
pairs=""
for a in $prs; do for b in $prs; do
  [ "$a" -lt "$b" ] || continue
  if ! git -C "$wt" merge-tree --write-tree "refs/queue/pr-$a" "refs/queue/pr-$b" >/dev/null 2>&1; then
    # a pair that clashes only in generated files is resolved on the batch
    pf=$(git -C "$wt" merge-tree --write-tree --name-only "refs/queue/pr-$a" "refs/queue/pr-$b" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    if [ "$(generated_only "$pf" "$gen_cfg")" != yes ]; then pairs="$pairs
$a $b"; fi
  fi
done; done
: > "$flaky_dir/now" 2>/dev/null || true
: > "$flaky_dir/clashes" 2>/dev/null || true
if [ -n "$pairs" ]; then
  group=$(anchored_group "$(printf '%s ' $prs)" "$pairs" | tr '\n' ' ')
  for pr in $prs; do
    case " $group " in *" $pr "*) continue ;; esac
    with=$(printf '%s\n' "$pairs" | awk -v p="$pr" -v g=" $group " '$1 == p && index(g, " " $2 " ") { print $2; exit } $2 == p && index(g, " " $1 " ") { print $1; exit }')
    files=$(git -C "$wt" merge-tree --write-tree --name-only "refs/queue/pr-$pr" "refs/queue/pr-$with" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    batch_line "$pr" "left for later" "conflicts with #$with, which goes in this batch"
    # The record names the files, the other change by its title, and why.
    printf '%s\t%s\t%s\t%s\t%s\n' "$pr" "$with" "$(pr_field "$with" 3 | tr '\t' ' ')" "$(printf '%s' "$files" | tr '\n' ' ' | sed 's/ *$//')" "conflicts with #$with, which goes in this batch" >> "$flaky_dir/clashes" 2>/dev/null || true
    notify_conflict "$pr" "$files" "$with"
  done
  prs=$group
fi
# How many rounds in a row each change left out has missed, and since
# when, kept across drains in the queue's own record (clash-rounds) and
# added to its clash line for the published state (spec 001). A round that
# leaves a change in ends its count.
cr_rec=$(clash_rounds "$(cat "$flaky_dir/clash-rounds" 2>/dev/null)" "$(cut -f1 "$flaky_dir/clashes" 2>/dev/null | tr '\n' ' ')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
printf '%s\n' "$cr_rec" | sed '/^$/d' > "$flaky_dir/clash-rounds" 2>/dev/null || true
cr_lines=$(clash_with_rounds "$(cat "$flaky_dir/clashes" 2>/dev/null)" "$cr_rec")
[ -z "$cr_lines" ] || printf '%s\n' "$cr_lines" > "$flaky_dir/clashes" 2>/dev/null || true
# The console shows the batch being built here, which takes minutes a
# pull request on a slow machine and once looked like a stalled queue:
# "building MERGED TOTAL CURRENT MEMBER...", cleared when the loop ends.
b_total=$(printf '%s\n' $prs | grep -c .)
b_merged=0
# The batch branch is cut: its members in order, the first the anchor.
: > "$flaky_dir/batch.state" 2>/dev/null || true
batch_note branch "$branch"
for pr in $prs; do batch_note member "$pr" "$(pr_field "$pr" 3)" planned; done
batch_moment cut
for pr in $prs; do
  printf 'building %s %s %s %s\n' "$b_merged" "$b_total" "$pr" "$(printf '%s ' $prs | sed 's/ $//')" > "$flaky_dir/now" 2>/dev/null || true
  hw=$(pr_held "$pr")
  if [ -n "$hw" ]; then batch_out "$pr" "left out" "$hw"; continue; fi
  # Read fresh, not from the cache: a pull request merged or closed since
  # the list was made has nothing left to merge.
  pst=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '"\(.state) \(.merged)"' 2>/dev/null || true)
  case "$pst" in
    "closed true") batch_out "$pr" "skipped" "already merged"; continue ;;
    closed*) batch_out "$pr" "skipped" "closed"; continue ;;
  esac
  why=$(folder_blocks "$pr"); [ -n "$why" ] || why=$(migration_blocks "$pr")
  if [ -n "$why" ]; then batch_out "$pr" "refused" "$why"; continue; fi
  # Merge the head the pull request reports: from its pull ref, or from
  # its branch when GitHub's pull ref lags behind.
  head=$(fetch_pr_head "$pr" "$wt") || { batch_out "$pr" "left for later" "$fph_why"; continue; }
  title=$(pr_field "$pr" 3); [ -n "$title" ] || title="PR $pr"
  if ! git -C "$wt" merge -q --no-ff --no-edit -m "Merge PR #$pr into $branch: $title" "$head" >/dev/null 2>&1; then
    git -C "$wt" merge --abort >/dev/null 2>&1 || true
    git -C "$wt" reset -q --hard "$good"
    cfl=$(git -C "$wt" merge-tree --write-tree --name-only "$good" "$head" 2>/dev/null | sed -n '2,$p' | sed '/^$/,$d')
    gen_note=""; if [ "$(generated_only "$cfl" "$gen_cfg")" = yes ]; then gen_note=generated; fi
    # Generated files only (scripts/ci/generated-paths.txt): take either
    # side, rebuild them here, and let the batch's one full run prove it.
    # Six green pull requests once landed one at a time for a package each
    # had rebuilt: an hour of landings for twenty minutes of work.
    if [ "$gen_note" = generated ] && git -C "$wt" merge -q --no-ff --no-edit -X theirs -m "Merge PR #$pr into $branch: $title" "$head" >/dev/null 2>&1; then
      rb=$(rebuild_command "$gen_cfg")
      if [ -n "$rb" ]; then
        if (cd "$wt" && sh -c "$rb") >/dev/null 2>"$flaky_dir/rebuild.err"; then
          git -C "$wt" add -A >/dev/null 2>&1 || true
          git -C "$wt" commit -q --amend --no-edit >/dev/null 2>&1 || true
          echo "  #$pr conflicted only in generated files; took either side and rebuilt them ($rb)."
        else
          git -C "$wt" reset -q --hard "$good"
          batch_out "$pr" "dropped" "conflicted only in generated files, but the rebuild failed: $(tail -n 1 "$flaky_dir/rebuild.err" 2>/dev/null | tr -d '\r')"
          dropped="$dropped $pr"
          continue
        fi
      else
        echo "  #$pr conflicted only in generated files; took either side. No rebuild: line in scripts/ci/generated-paths.txt, so the batch's full run must prove them."
      fi
    else
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      git -C "$wt" reset -q --hard "$good"
      if [ "$gen_note" = generated ]; then
        batch_out "$pr" "dropped" "conflicts with the batch so far; generated only: a rebuild on the batch would resolve this"
      else
        batch_out "$pr" "dropped" "conflicts with the batch so far"
      fi
      notify_conflict "$pr" "$cfl" main "$gen_note"
      dropped="$dropped $pr"
      continue
    fi
  fi
  # A merge that joins template changes makes a version nobody hashed:
  # derive the known-hashes list again and commit it before the run.
  kr_line=$(known_refresh "$wt" "$good")
  [ -z "$kr_line" ] || batch_line "$pr" "merged" "$kr_line"
  changed=$(git -C "$wt" diff --name-only "origin/$base...$head")
  # a member that changes dependencies gets them installed before its check
  case "
$changed" in *"
package-lock.json"*|*"/package-lock.json"*|*"pnpm-lock.yaml"*|*"yarn.lock"*|*"
package.json"*|*"/package.json"*) ensure_modules ;; esac
  if [ -n "$typecheck" ] && ! typecheck_ok "$changed" "$wt"; then
    git -C "$wt" reset -q --hard "$good"
    batch_out "$pr" "dropped" "the type-check went red after merging it: $(head -n 1 "$flaky_dir/typecheck.err" 2>/dev/null | tr -d '\r')"
    dropped="$dropped $pr"
    continue
  fi
  red=""; not_run=""
  for f in $(tests_for_diff "$changed"); do
    [ -f "$wt/$f" ] || continue
    rc=0; (cd "$wt" && $test_one "$f") >/dev/null 2>"$flaky_dir/test.err" || rc=$?
    if [ "$rc" -eq 3 ]; then
      # Its runner could not be told: not run here, never red.
      not_run="$not_run $f"
      continue
    fi
    if [ "$rc" -eq 2 ]; then
      # The runner could not start. That is not a red test, and dropping
      # every pull request for it would empty the batch for nothing.
      echo "The test runner could not run $f: $(tail -n 3 "$flaky_dir/test.err" 2>/dev/null | tr '\r\n' '  ')"
      echo "Nothing was dropped for it. Fix the runner, or set QUEUE_TEST_COMMAND to the project's one-file test command, and run the batch again."
      git -C "$wt" reset -q --hard "$good"
      exit 1
    fi
    if [ "$rc" -ne 0 ]; then
      red=$f
      [ -s "$flaky_dir/test.err" ] && echo "  $(tail -n 3 "$flaky_dir/test.err" | tr '\r\n' '  ')"
      break
    fi
  done
  if [ -n "$red" ]; then
    git -C "$wt" reset -q --hard "$good"
    batch_out "$pr" "dropped" "$red went red after merging it"
    dropped="$dropped $pr"
    continue
  fi
  [ -z "$not_run" ] || batch_line "$pr" "kept" "not run here:$not_run (its test runner could not be told; the batch's full run covers it)"
  # Cancel the PR's own CI run; the batch's one run covers it.
  # Queued runs too: a queued member run still takes a runner the moment
  # one frees, ahead of the batch. A run that ignores the cancel (jobs
  # already picked up) is force-cancelled.
  gh run list --branch "$(pr_field "$pr" 1)" --json databaseId,status -q '.[] | select(.status != "completed") | .databaseId' 2>/dev/null \
    | while read -r id; do
      [ -n "$id" ] || continue
      gh_write run cancel "$id" >/dev/null 2>&1 || true
      sleep 5
      [ "$(gh api "repos/{owner}/{repo}/actions/runs/$id" --jq .status 2>/dev/null)" = completed ] || gh_write api -X POST "repos/{owner}/{repo}/actions/runs/$id/force-cancel" >/dev/null 2>&1 || true
    done
  good=$(git -C "$wt" rev-parse HEAD)
  carried="$carried$pr	$title
"
  refs="$refs$(carried_refs "$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '.body // ""' 2>/dev/null)" "$pr")
"
  batch_line "$pr" "merged into the batch"; batch_note member "$pr" "$title" merged; batch_moment building
  b_merged=$((b_merged + 1))
done
: > "$flaky_dir/now" 2>/dev/null || true

# One member is not a batch: GitHub refused a one-member batch pull request
# because its required check had not run yet, and the member's own green
# run already proves it. Merge it serially instead.
if [ -n "$carried" ] && [ "$(printf '%s\n' "$carried" | grep -c .)" -eq 1 ]; then
  only=$(printf '%s' "$carried" | cut -f1)
  echo "Only #$only survived the batch; merging it serially instead of opening a batch of one."
  because="batch of one"
  : > "$flaky_dir/batch.state" 2>/dev/null || true
  serial_one "$only"
  for pr in $dropped; do serial_one "$pr"; done
  exit 0
fi

if [ -z "$carried" ]; then
  echo "Nothing survived the batch; running the serial queue for all of them."
  : > "$flaky_dir/batch.state" 2>/dev/null || true
  because="dropped from batch"
  for pr in $dropped; do serial_one "$pr"; done
  exit 0
fi

if [ -f "$wt/status/build.sh" ]; then
  (cd "$wt" && sh status/build.sh) >/dev/null
  if ! git -C "$wt" diff --quiet -- STATUS.md; then
    git -C "$wt" add STATUS.md && git -C "$wt" commit -q -m "Rebuild the status page for $branch"
  fi
fi

gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq '.[] | select((.body // "") | (contains("<!-- merge-queue:batch -->") or startswith("One integration run for the pull requests below"))) | .number' 2>/dev/null \
  | while read -r old; do if [ -n "$old" ]; then close_pr "$old" "Superseded by a new batch from the queue; its members are carried there if still green."; fi; done

git -C "$wt" push -q -u origin "$branch"
body=$(batch_pr_body "$carried" "$refs")
batch_pr=$(gh_write api -X POST "repos/{owner}/{repo}/pulls" -f base="$base" -f head="$branch" -f title="Batch $day: $(printf '%s' "$carried" | wc -l | tr -d ' ') pull requests" -f body="$body" --jq .number 2>"$gh_err") || { rate_stop; echo "Could not open the batch pull request: $(head -n 1 "$gh_err" 2>/dev/null). The branch $branch is pushed; open it by hand or run the batch again."; exit 1; }
echo "batch PR #$batch_pr opened; waiting for the one full CI run"; ci_dispatch "$branch"
batch_note pr "$batch_pr"; batch_moment testing
batch_sha=$(git -C "$wt" rev-parse HEAD)
batch_ok=no
# The members, so a request read during the run knows which classes it runs.
printf '%s\n' "$carried" | cut -f1 > "$flaky_dir/batch.members" 2>/dev/null || true
if [ "$have_lock" = yes ]; then trap ': > "$flaky_dir/batch.members" 2>/dev/null; queue_exit' EXIT; else trap ': > "$flaky_dir/batch.members" 2>/dev/null' EXIT; fi
if wait_for_run "$batch_pr" "$branch" && wait_required "$batch_sha"; then batch_ok=yes
else
  # A job cancelled before a runner took it fails the required check
  # without anything being wrong: re-run the failed and cancelled jobs once
  # and wait again, rather than close a good batch.
  # A cancelled job whose own step failed reads as failed (check_lines), so
  # a real failure that cancelled its siblings is never re-run here.
  checks=$(check_lines "$batch_sha" 2>/dev/null)
  if [ "$(rest_rollup_named "$checks" "${QUEUE_SUMMARY_CHECK:-CI passed}")" = cancelled ]; then
    run=$(latest_run "$branch"); run_id=${run%%	*}
    if [ -n "$run_id" ] && gh_write run rerun "$run_id" --failed >/dev/null 2>&1; then
      echo "A job on the batch was cancelled before it ran; re-ran the failed and cancelled jobs and waiting again."
      sleep 30
      wait_for_run "$batch_pr" "$branch" && wait_required "$batch_sha" && batch_ok=yes
    fi
  fi
fi
if [ "$batch_ok" != yes ]; then
  close_pr "$batch_pr" "The batch's CI was not green, so nothing merged; closed so the next batch starts clean. The member pull requests are untouched."
  echo "The batch run is not green; nothing merged. Fix it on $branch or drop a PR and run again."
  exit 1
fi
wait_quiet_main
merged_sha=$(gh_write api -X PUT "repos/{owner}/{repo}/pulls/$batch_pr/merge" -f merge_method=merge --jq .sha 2>"$gh_err") || { rate_stop; echo "GitHub refused the batch merge: $(head -n 1 "$gh_err" 2>/dev/null). Nothing merged; run the batch again."; exit 1; }
echo "batch PR #$batch_pr merged into $base with a merge commit"; ci_dispatch "$base"
batch_moment landed
# GitHub can show a carried pull request as "closed, not merged", which
# reads as abandoned. Say on each where it went.
for pr in $(printf '%s' "$carried" | cut -f1); do
  gh_write api -X POST "repos/{owner}/{repo}/issues/$pr/comments" -f body="Merged into $base in batch #$batch_pr (commit ${merged_sha:-unknown}), with its history kept. GitHub may show this pull request as closed rather than merged; its changes are on $base." >/dev/null 2>&1 || true
  echo "#$pr merged via batch #$batch_pr"
done
for pr in $(printf '%s' "$carried" | cut -f1); do
  tidy_worktree "$(pr_field "$pr" 1)"
done

if [ -n "$dropped" ]; then
  echo "serial queue for the dropped PRs:$dropped"
  because="dropped from batch"
  for pr in $dropped; do serial_one "$pr"; done
fi
if [ -z "$QUEUE_IN_DRAIN" ]; then deploy_if_due "$b_begin"; fi
}
