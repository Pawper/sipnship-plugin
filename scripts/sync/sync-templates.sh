#!/bin/sh
# Bring a project's copies of the plugin's scripts up to date with the
# installed plugin. A project copies the templates once, at bootstrap, and
# nothing refreshes them, so a project can run a merge queue from weeks ago
# while the plugin has moved on: one project asked for a batch mode its own
# copy of the queue did not have.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/sync/sync-templates.sh"          report only
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/sync/sync-templates.sh" --apply  update, on a new branch
#   ... --apply --force   also replace plugin-owned files the project edited
#   ... --apply --no-commit   write and stage, but leave the commit to the
#                             agent, so it carries the session's attribution
# A path in .claude/project-owned.txt (one per line) is the project's from
# then on: listed, never compared or written. A generator that outgrew the
# template (scripts/design/generate.mjs with blocks of its own) goes there.
#
# What it does with each kind of file:
#   - Plugin-owned scripts and workflows (templates/OWNED.txt): reported when
#     missing or different; with --apply, written from the plugin. One the
#     project has edited since it was copied (more than one commit touches
#     it) is kept and named, unless --force: a local exception in a check
#     was once replaced without a word, and CI went red on the next push.
#   - Config with defaults: added when missing; never replaced.
#   - The project's own files (ci.yml, .gitattributes, .gitignore):
#     never touched; it reports the jobs and lines the template has that
#     the project's copy lacks, for a person to merge by hand.
#
# --apply needs a clean working tree. It makes a branch named
# template-sync-<date> from the current commit, writes the files there and
# commits them, so every change is a reviewable diff in a pull request and
# the old versions stay in git. It does not push.
here=$(dirname "$0")
. "$here/sync-lib.sh"
plugin=$(cd "$here/../.." && pwd)
tpl="$plugin/templates"
apply=no; force=no; only=""; no_commit=no
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=yes ;;
    --force) force=yes ;;
    --no-commit) no_commit=yes ;;
    --only) shift; only=$(printf '%s' "$1" | tr ',' ' ') ;;
    --only=*) only=$(printf '%s' "${1#--only=}" | tr ',' ' ') ;;
  esac
  shift
done
# The command for this plugin, by its real path: $CLAUDE_PLUGIN_ROOT is set
# for hooks but empty in an agent's Bash tool, so a command printed with it
# fails as typed.
self="sh \"$plugin/scripts/sync/sync-templates.sh\""

git rev-parse --git-dir >/dev/null 2>&1 || { echo "Run this from the project's root, inside its git repository." >&2; exit 2; }
version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$plugin/.claude-plugin/plugin.json" | head -n 1)
owned=$(cat "$tpl/OWNED.txt")

# Features: refresh and complete the ones this project uses; report, never
# add, the ones it has none of, since it may have its own tools for them.
# --only names the features to touch, adopted or not.
features=$(owned_features "$owned")
present=""; for p in $(owned_paths "$owned"); do [ -f "$p" ] && present="$present$p
"; done
adopted=$(adopted_features "$features" "$present")
# A file the project already has is always refreshed (within --only); a
# missing one is added only for a feature in use or named with --only.
in_scope() {
  is_f=$(feature_of "$features" "$1")
  if [ -n "$only" ]; then case " $only " in *" $is_f "*) return 0 ;; *) return 1 ;; esac; fi
  [ -f "$1" ] && return 0
  case " $adopted " in *" $is_f "*) return 0 ;; *) return 1 ;; esac
}
# Where the project's jobs run and in which shell, from its own ci.yml:
# filled into the workflows the sync writes, and into the template a
# workflow is compared against.
runs_on=""; run_shell=""
if [ -f .github/workflows/ci.yml ]; then
  runs_on=$(ci_runs_on "$(cat .github/workflows/ci.yml)")
  run_shell=$(ci_shell "$(cat .github/workflows/ci.yml)")
fi
changed=""; missing=""; current=0; unadopted=""
project_owned=$(sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' .claude/project-owned.txt 2>/dev/null || true)
for p in $(owned_paths "$owned"); do
  case "
$project_owned
" in *"
$p
"*) echo "  project:  $p (listed in .claude/project-owned.txt; never compared or written)"; continue ;; esac
  if ! in_scope "$p"; then
    [ -f "$p" ] || unadopted="$unadopted $(feature_of "$features" "$p")"
    continue
  fi
  if [ ! -f "$p" ]; then missing="$missing $p"; continue; fi
  case "$p" in
    .github/workflows/*.yml) want=$(filled_text "$(cat "$tpl/$p")" "$runs_on" "$run_shell") ;;
    *) want=$(cat "$tpl/$p") ;;
  esac
  if [ "$(same_text "$(cat "$p")" "$want")" = yes ]; then current=$((current + 1)); else changed="$changed $p"; fi
done
defaults=""
# A feature's config defaults go to a project that uses the feature; one
# that does not use it does not need its config.
if [ -z "$only" ]; then
  for af in $adopted; do for p in $(default_paths "$owned" "$af"); do [ -f "$p" ] || defaults="$defaults $p"; done; done
fi

echo "Plugin $version. Plugin-owned files here: $current current, $(printf '%s' "$changed" | wc -w | tr -d ' ') older or edited, $(printf '%s' "$missing" | wc -w | tr -d ' ') missing."
edited=""
for p in $changed; do
  # A file committed more than once has been edited in this project since
  # it was copied; the refresh would replace that edit, so say so, and
  # with --apply keep it unless --force.
  n=$(git log --oneline -- "$p" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -gt 1 ]; then
    echo "  differs:  $p (edited here in $((n - 1)) later commit(s); kept unless --force; check that diff and carry the edit into the template or an issue)"
    case "$p" in scripts/design/generate.mjs) echo "            a generator that grew blocks of its own is the project's now: add the line scripts/design/generate.mjs to .claude/project-owned.txt, or move the extra output into scripts/design/generate.local.mjs (its extra() hook)" ;; esac
    edited="$edited $p"
  else echo "  differs:  $p"; fi
done
for p in $missing; do echo "  missing:  $p"; done
if [ -n "$unadopted" ] && [ -z "$only" ]; then
  for f in $(printf '%s\n' $unadopted | awk '!seen[$0]++'); do
    n=$(printf '%s\n' "$features" | awk -F'\t' -v f="$f" '$1 == f' | wc -l | tr -d ' ')
    anchor=$(printf '%s\n' "$features" | awk -F'\t' -v f="$f" '$1 == f { print $2; exit }')
    echo "  not used: the $f feature ($n files; its main file $anchor is not here). The project may have its own tools for it, so its missing files are not added. To add it: $self --apply --only $f"
  done
fi
[ -z "$only" ] || echo "Only the $only feature(s)."
for p in $defaults; do echo "  new config, would be added with its defaults: $p"; done

# The project's own files: report what the template gained (not with
# --only, which is about one feature).
if [ -z "$only" ] && [ -f .github/workflows/ci.yml ]; then
  jobs=$(missing_jobs "$(cat "$tpl/.github/workflows/ci.yml")" "$(cat .github/workflows/ci.yml)")
  split=$(split_checks "$(cat .github/workflows/ci.yml)")
  if [ -n "$split" ]; then
    echo "  ci.yml is yours and still runs $(printf '%s\n' "$split" | grep -c .) cheap checks as jobs of their own ($(printf '%s' "$split" | tr '\n' ' ' | sed 's/ $//')). The template now runs them as steps of one \"checks\" job and the install, tests and build in one \"app\" job, with a concurrency group: about 3 runner jobs a pull request instead of 10. How to move: $plugin/CI-MIGRATION.md"
    jobs=$(printf '%s\n' "$jobs" | grep -vxF checks || true)
  fi
  if ! grep -q 'pull-requests: read' .github/workflows/ci.yml; then
    echo "  ci.yml is yours and cannot read pull requests: add \"pull-requests: read\" under permissions so checks read the live body (a re-run keeps the old one). How: $plugin/CI-MIGRATION.md, section 0.10.1"
  fi
  [ -n "$jobs" ] && echo "  ci.yml is yours; the template has jobs it lacks: $(printf '%s' "$jobs" | tr '\n' ' ')(copy them from $tpl/.github/workflows/ci.yml and add each to CI passed)"
fi
# A release workflow that builds on every merge (workflow_run of CI) is
# the project's own file; say so, and how to make it follow Deploy.
for wf_f in .github/workflows/*.yml; do
  [ -z "$only" ] && [ -f "$wf_f" ] || continue
  if [ "$(per_merge_release "$(cat "$wf_f")")" = yes ]; then
    echo "  $wf_f builds a release on every merge to main (it starts on workflow_run of CI). Make it follow Deploy instead: workflow_run of Deploy plus workflow_dispatch, and list it under \"releases\" in .claude/deploy.json. How: $tpl/scripts/ci/QUEUE.md, \"Release channels follow Deploy\""
  fi
done
for f in .gitattributes .gitignore; do
  [ -z "$only" ] && [ -f "$f" ] || continue
  lines=$(missing_lines "$(cat "$tpl/$f")" "$(cat "$f")")
  if [ -n "$lines" ]; then echo "  $f is yours; the template has lines it lacks: $(printf '%s' "$lines" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"; fi
done

# Numbering: a migration glob that matches no file, while a common folder
# holds migrations, makes next-number answer 0001 and the gate refuse real
# ones. Say which line to write.
if [ -f .claude/numbering.txt ] && [ -f "$tpl/scripts/ci/numbering-lib.sh" ]; then
  . "$tpl/scripts/ci/numbering-lib.sh"
  mg=$(numbering_glob "$(cat .claude/numbering.txt)" migration)
  if [ -n "$mg" ]; then
    tracked=$(git ls-files 2>/dev/null)
    set -f; hit=$(printf '%s\n' "$tracked" | while IFS= read -r f; do case "$f" in $mg) echo y; break ;; esac; done); set +f
    guess=$(migration_glob_guess "$tracked")
    if [ -z "$hit" ] && [ -n "$guess" ] && [ "$guess" != "$mg" ]; then
      echo "  numbering: .claude/numbering.txt says migrations are \"$mg\", which matches no file; they are in \"$guess\". Change the line to: migration $guess"
    fi
  fi
fi

# Deploys: a project that deploys to Vercel with no guard builds every
# branch; one with a hand-written guard may diff HEAD^..HEAD, which drops
# the changes a skipped build held. Offer the setup either way.
if [ -f "$tpl/scripts/ci/deploy-lib.sh" ]; then
  . "$tpl/scripts/ci/deploy-lib.sh"
  vj=$(git ls-files 'vercel.json' '*/vercel.json' 2>/dev/null | head -n 1)
  vercel=no
  { [ -n "$vj" ] || [ -d .vercel ] || grep -q '"vercel"\|"next"' package.json */package.json 2>/dev/null; } && vercel=yes
  if [ "$vercel" = yes ] && [ ! -f .claude/deploy.json ]; then
    kind=none; [ -n "$vj" ] && kind=$(guard_kind "$(cat "$vj")")
    app=.; [ -n "$vj" ] && app=$(dirname "$vj")
    case "$kind" in
      handwritten) echo "  deploys:  $vj has a hand-written guard$(grep -q 'HEAD^' "$vj" && printf ' that diffs HEAD^..HEAD: when a push ends in a docs-only commit, the app changes before it are skipped and never deploy'); replace it with the plugin's guard, the same kind of setup done right: $self --apply --only deploy, then sh scripts/deploy-setup.sh guard $app. Whether it is already merged makes no difference; the setup rewrites vercel.json either way" ;;
      none) echo "  deploys:  this project deploys to Vercel with nothing keeping build CPU down; every branch builds. Run: $self --apply --only deploy, then sh scripts/deploy-setup.sh \"\" $app" ;;
    esac
  fi
fi

work=$(printf '%s%s%s' "$changed" "$missing" "$defaults" | tr -d ' ')
if [ -z "$work" ]; then echo "Everything the plugin owns is current."; exit 0; fi
# A project that still passes --deploy (gone in 0.16.0) wanted a deploy
# after every landing: intervalMinutes 0 is that, unless another pull
# request is green.
if [ -f .claude/deploy.json ] && git grep -qE 'merge-queue\.sh.*--deploy|--drain-then-deploy' -- . ':(exclude)scripts/ci/merge-queue.sh' ':(exclude)scripts/ci/QUEUE.md' 2>/dev/null; then
  echo "  deploys:  files here still pass --deploy, which 0.16.0 removed; the queue deploys from state now. For a deploy after every landing (unless another pull request is green), set \"intervalMinutes\": 0 in .claude/deploy.json, and drop the flag."
fi
# Releases listed with no releaseOn, on a deploy after every landing.
if [ -f .claude/deploy.json ] && grep -q '"releases"' .claude/deploy.json && ! grep -q '"releaseOn"' .claude/deploy.json && grep -qE '"intervalMinutes"[[:space:]]*:[[:space:]]*0[^0-9]' .claude/deploy.json; then
  echo "  releases: .claude/deploy.json lists release workflows with intervalMinutes 0 and no releaseOn, so the queue starts them after every landing that ships. To hold them until asked, add \"releaseOn\": \"ask\" and start them with merge-queue.sh --release."
fi
# A rebuild a hosted drain may not be able to run.
if grep -qs '^[[:space:]]*rebuild:' scripts/ci/generated-paths.txt && command -v gh >/dev/null 2>&1; then
  if gh api "repos/{owner}/{repo}/actions/variables/DEPLOY_JOBS_ON" >/dev/null 2>&1; then
    echo "  deploy:   the repository variable DEPLOY_JOBS_ON is no longer read; Deploy's plan runs where ci.yml's jobs run. Remove it: gh variable delete DEPLOY_JOBS_ON"
  fi
  qro=$(gh api "repos/{owner}/{repo}/actions/variables/QUEUE_RUNS_ON" --jq .value 2>/dev/null) || qro=""
  case "$qro" in ''|ubuntu*|windows-latest|macos*) echo "  queue:    scripts/ci/generated-paths.txt names a rebuild, and the scheduled drain runs hosted (${qro:-ubuntu-latest}); if the rebuild needs your machine, set the repository variable QUEUE_RUNS_ON to its runner's label." ;; esac
fi
if [ "$apply" = no ]; then echo "Nothing was changed. To write these on a branch: $self --apply${only:+ --only $(printf '%s' "$only" | tr ' ' ',')}"; exit 0; fi

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "The working tree has uncommitted changes; commit or move them aside first." >&2; exit 1; }
# On a branch made for the sync (anything but the default branch), commit
# there; on the default branch, cut a dated one. A worktree on 556-plugin-sync
# once got a second branch it never asked for.
current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
default=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
case "$current" in
  ''|HEAD|main|master|"${default:-main}")
    branch="template-sync-$(date +%Y-%m-%d)"
    git show-ref --verify --quiet "refs/heads/$branch" && branch="$branch-$(date +%H%M)"
    git checkout -q -b "$branch" ;;
  *) branch=$current ;;
esac
# A workflow the sync adds carries RUNS_ON and RUN_SHELL, filled from the
# project's ci.yml (read above).
written=""
for p in $changed $missing $defaults; do
  if [ "$force" = no ]; then
    case " $edited " in *" $p "*) echo "  kept:     $p (edited here; pass --force to replace it)"; continue ;; esac
  fi
  mkdir -p "$(dirname "$p")"
  cp "$tpl/$p" "$p"
  case "$p" in *.sh) chmod +x "$p" 2>/dev/null || true ;; esac
  if [ "$p" = .claude/numbering.txt ]; then
    . "$tpl/scripts/ci/numbering-lib.sh"
    g=$(migration_glob_guess "$(git ls-files 2>/dev/null)")
    if [ -n "$g" ]; then
      awk -v g="$g" '/^migration[ \t]/ && !done { print "migration " g; done = 1; next } { print }' "$p" > "$p.tmp" && mv "$p.tmp" "$p"
      echo "  numbering: migrations are in $g here; .claude/numbering.txt says so"
    fi
  fi
  case "$p" in
    .github/workflows/*.yml)
      if [ -n "$runs_on" ] && grep -qw 'RUNS_ON' "$p"; then
        fill_placeholder "$(cat "$p")" RUNS_ON "$runs_on" > "$p.tmp" && mv "$p.tmp" "$p"
        echo "  filled:   RUNS_ON in $p from ci.yml ($runs_on)"
      fi
      if [ -n "$run_shell" ] && grep -qw 'RUN_SHELL' "$p"; then
        fill_placeholder "$(cat "$p")" RUN_SHELL "$run_shell" > "$p.tmp" && mv "$p.tmp" "$p"
        echo "  filled:   RUN_SHELL in $p from ci.yml"
      fi
      needs=$(workflow_needs "$(cat "$p")")
      [ -n "$needs" ] && echo "  needs:    $p reads $needs; set them in the repository before its first run"
      grep -qw 'RUNS_ON\|RUN_SHELL' "$p" && echo "  todo:     $p still has a RUNS_ON or RUN_SHELL placeholder to fill"
      # A workflow with a stray control byte fails every run with no jobs
      # and nothing says why; refuse to commit one.
      if [ "$(control_bytes "$(cat "$p")")" = yes ]; then
        echo "  refused:  $p holds a control character after filling; not committing. Check the shell line in ci.yml." >&2
        git checkout -q -- "$p" 2>/dev/null || rm -f "$p"
        exit 1
      fi ;;
  esac
  written="$written $p"
done
[ -n "$(printf '%s' "$written" | tr -d ' ')" ] || { echo "Nothing written: every differing file was edited here. Pass --force to replace them."; git checkout -q -; exit 0; }
# Scripts must stay LF: a repository that checks out CRLF breaks every
# shell script it copies. Pin the types the sync writes, once.
lf_add=""
for ext in sh mjs; do
  for p in $written; do
    case "$p" in *."$ext")
      case "$(git check-attr eol -- "$p" 2>/dev/null)" in *": eol: lf") ;; *) lf_add="$lf_add *.$ext" ;; esac
      break ;;
    esac
  done
done
if [ -n "$lf_add" ]; then
  for pat in $lf_add; do printf '%s text eol=lf\n' "$pat" >> .gitattributes; done
  git add .gitattributes
  for p in $written; do git add --renormalize -- "$p" 2>/dev/null || true; done
  echo "  pinned:   $lf_add to LF in .gitattributes, since this repository checks out CRLF"
fi
git add -- $written
if [ "$no_commit" = yes ]; then
  echo "Staged on branch $branch, not committed (--no-commit). Commit it yourself, with your session's attribution; then push and open a pull request. Secrets and variables named above must exist before the added workflows run."
else
  git commit -q -m "Sync the plugin's scripts and workflows to sipnship $version" -m "Plugin-owned files were brought up to date with the installed plugin; config files that did not exist were added with their defaults. Files the project owns, and plugin-owned files the project had edited, were not touched."
  echo "Committed on branch $branch. Review the diff, then push it and open a pull request. Secrets and variables named above must exist before the added workflows run. An agent that wants its own attribution on the commit passes --no-commit."
fi
# New state labels arrive with labels.sh; state.sh fails until they exist.
case " $written " in
  *" scripts/labels.sh "*)
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && sh scripts/labels.sh >/dev/null 2>&1; then
      echo "Labels are current: scripts/labels.sh ran, so any new state label exists before scripts/state.sh needs it."
    else
      echo "Run sh scripts/labels.sh once gh is signed in, so any new state label exists before scripts/state.sh needs it."
    fi ;;
esac
