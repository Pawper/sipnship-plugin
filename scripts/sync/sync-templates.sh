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
#     missing or different; with --apply, written from the plugin. A file is
#     judged by its content against every released version
#     (templates/KNOWN.txt), never by its name or its commit messages:
#       matches a version now      the plugin's, refreshed;
#       matched one once, not now  edited here, kept and named unless
#                                  --force (a local exception in a check
#                                  was once replaced without a word);
#       never matched one          the project's own: never compared or
#                                  replaced, --force included, and not a
#                                  sign the feature is in use. A sync once
#                                  replaced a project's own audit and
#                                  state-label workflows and they failed
#                                  every night after.
#     A workflow is built in memory and written only when its RUNS_ON and
#     RUN_SHELL could be filled and every script it runs is here or written
#     in the same sync.
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
known=$(cat "$tpl/KNOWN.txt" 2>/dev/null || true)
# Where the project's jobs run and in which shell, from its own ci.yml:
# filled into the workflows the sync writes, and used to recognise a filled
# workflow as a released version.
runs_on=""; run_shell=""
if [ -f .github/workflows/ci.yml ]; then
  runs_on=$(ci_runs_on "$(cat .github/workflows/ci.yml)")
  run_shell=$(ci_shell "$(cat .github/workflows/ci.yml)")
fi

# Features: refresh and complete the ones this project uses; report, never
# add, the ones it has none of, since it may have its own tools for them.
# --only names the features to touch, adopted or not.
features=$(owned_features "$owned")
# origin_of PATH: "plugin" when the file here is a released version,
# "edited" when an earlier commit of it was and it has changed since, "own"
# when it never was one.
origin_of() {
  [ -n "$known" ] || { echo plugin; return; }
  [ "$(known_match "$known" "$1" "$(cat "$1")" "$runs_on" "$run_shell")" = yes ] && { echo plugin; return; }
  for o_rev in $(git log --format=%H -- "$1" 2>/dev/null); do
    o_t=$(git show "$o_rev:$1" 2>/dev/null) || continue
    if [ "$(known_match "$known" "$1" "$o_t" "$runs_on" "$run_shell")" = yes ]; then echo edited; return; fi
  done
  echo own
}
present=""; own=""; edited=""
for p in $(owned_paths "$owned"); do
  [ -f "$p" ] || continue
  case "$(origin_of "$p")" in
    plugin) present="$present$p
" ;;
    edited) present="$present$p
"; edited="$edited $p" ;;
    own) own="$own $p" ;;
  esac
done
adopted=$(adopted_features "$features" "$present")
# A file the project already has is always refreshed (within --only); a
# missing one is added only for a feature in use or named with --only.
in_scope() {
  is_f=$(feature_of "$features" "$1")
  if [ -n "$only" ]; then case " $only " in *" $is_f "*) return 0 ;; *) return 1 ;; esac; fi
  [ -f "$1" ] && return 0
  case " $adopted " in *" $is_f "*) return 0 ;; *) return 1 ;; esac
}
changed=""; missing=""; current=0; unadopted=""
project_owned=$(sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' .claude/project-owned.txt 2>/dev/null || true)
for p in $(owned_paths "$owned"); do
  case "
$project_owned
" in *"
$p
"*) echo "  project:  $p (listed in .claude/project-owned.txt; never compared or written)"; continue ;; esac
  case " $own " in *" $p "*) echo "  own:      $p is this project's own file (it matches no SipNShip version); never compared or replaced, --force included"; continue ;; esac
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

# A workflow or script the sync writes brings the plugin-owned scripts it
# runs, and theirs, whatever feature they belong to: runner-watch.yml runs
# scripts/ci/runner-doctor.sh, which loads doctor-lib.sh, and a project
# that had the workflow but not the doctor was told "0 missing" and then
# had the workflow refused on --apply.
owned_list=" $(owned_paths "$owned" | tr '\n' ' ') "
dep_todo="$(printf '%s' "$present" | tr '\n' ' ') $missing"
while [ -n "$(printf '%s' "$dep_todo" | tr -d ' ')" ]; do
  dep_next=""
  for p in $dep_todo; do
    [ -f "$tpl/$p" ] || continue
    case "
$project_owned
" in *"
$p
"*) continue ;; esac
    case "$p" in
      .github/workflows/*.yml) deps=$(sourced_scripts "$(cat "$tpl/$p")") ;;
      *.sh) deps=$(printf '%s\n%s\n' "$(loaded_scripts "$(cat "$tpl/$p")")" "$(here_scripts "$(cat "$tpl/$p")" "$(dirname "$p")")") ;;
      *) continue ;;
    esac
    for d in $deps; do
      [ -f "$d" ] && continue
      case "$owned_list" in *" $d "*) ;; *) continue ;; esac
      case " $missing " in *" $d "*) continue ;; esac
      case "
$project_owned
" in *"
$d
"*) continue ;; esac
      missing="$missing $d"; dep_next="$dep_next $d"
      echo "  brings:   $d, which $p runs"
    done
  done
  dep_todo=$dep_next
done
willwrite=" $changed $missing $defaults "
# refusal_of PATH: why a workflow cannot be written here, or nothing. The
# dry run and --apply both ask, so what one says the other does.
refusal_of() {
  case "$1" in .github/workflows/*.yml) ;; *) return 0 ;; esac
  r_text=$(filled_text "$(cat "$tpl/$1")" "$runs_on" "$run_shell")
  if printf '%s\n' "$r_text" | grep -qw 'RUNS_ON\|RUN_SHELL'; then
    echo "needs to know where this project's jobs run, and ci.yml has no plain runs-on or shell to copy (none, or an expression); not written. Give ci.yml's first job a plain runs-on and shell, or write this file by hand."
    return 0
  fi
  r_missing=""
  for r_s in $(sourced_scripts "$r_text"); do
    [ -f "$r_s" ] && continue
    case "$willwrite" in *" $r_s "*) continue ;; esac
    r_missing="$r_missing $r_s"
  done
  if [ -n "$r_missing" ]; then
    echo "runs$r_missing, which this project does not have and the plugin does not ship; not written, since it would fail on every run."
    return 0
  fi
  if [ "$(control_bytes "$r_text")" = yes ]; then
    echo "would hold a control character after filling; not written. Check the shell line in ci.yml."
  fi
  return 0
}
refused=""
for p in $changed $missing; do
  if [ "$force" = no ]; then case " $edited " in *" $p "*) continue ;; esac; fi
  why=$(refusal_of "$p")
  if [ -n "$why" ]; then refused="$refused $p"; fi
done
echo "Plugin $version. Plugin-owned files here: $current current, $(printf '%s' "$changed" | wc -w | tr -d ' ') older or edited, $(printf '%s' "$missing" | wc -w | tr -d ' ') missing."
for p in $changed; do
  case " $edited " in
    *" $p "*)
      echo "  differs:  $p (edited here since it was synced; kept unless --force; check that diff and carry the edit into the template or an issue)"
      case "$p" in scripts/design/generate.mjs) echo "            a generator that grew blocks of its own is the project's now: add the line scripts/design/generate.mjs to .claude/project-owned.txt, or move the extra output into scripts/design/generate.local.mjs (its extra() hook)" ;; esac ;;
    *) echo "  differs:  $p" ;;
  esac
done
for p in $missing; do echo "  missing:  $p"; done
for p in $refused; do echo "  refused:  $p $(refusal_of "$p")"; done
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
# The queue's published state (spec 001) is on when the project says so.
if [ -f scripts/ci/merge-queue.sh ] && [ -f "$tpl/scripts/ci/publish-state.sh" ] && command -v gh >/dev/null 2>&1; then
  qps=$(gh api "repos/{owner}/{repo}/actions/variables/QUEUE_PUBLISH_STATE" --jq .value 2>/dev/null) || qps=""
  [ "$qps" = issue ] || echo "  publish:  the merge queue can keep a \"Merge queue\" issue current with what it is doing, for anyone who can see the repository: gh variable set QUEUE_PUBLISH_STATE --body issue, then pin the issue it creates. sh scripts/ci/publish-state.sh --print shows the body first."
fi
# A project with its own runners spends no hosted minutes by default: the
# scheduled drain runs on them (QUEUE_RUNS_ON, set here with --apply), and
# the runner watch is a task on their machine, not a hosted job.
case "$runs_on" in
  *self-hosted*)
    if command -v gh >/dev/null 2>&1; then
      qro=$(gh api "repos/{owner}/{repo}/actions/variables/QUEUE_RUNS_ON" --jq .value 2>/dev/null) || qro=""
      q_label=$(printf '%s' "$runs_on" | tr -d '[]' | tr ',' '\n' | sed 's/^[ \t]*//; s/[ \t]*$//' | grep -vix 'self-hosted' | head -n 1)
      case "$qro" in
        ''|ubuntu*|windows-latest|macos*)
          if [ "$apply" = yes ] && [ -n "$q_label" ] && gh variable set QUEUE_RUNS_ON --body "$q_label" >/dev/null 2>&1; then
            echo "  queue:    the scheduled drain now runs on this project's runners (QUEUE_RUNS_ON=$q_label); it ran hosted before, a billed minute every run in a private repository."
          else
            echo "  queue:    the scheduled drain runs hosted (${qro:-ubuntu-latest}) though this project has its own runners; run with --apply to set QUEUE_RUNS_ON=${q_label:-<label>}, or: gh variable set QUEUE_RUNS_ON --body ${q_label:-<label>}"
          fi ;;
      esac
      if [ -f .github/workflows/runner-watch.yml ] && [ -f "$tpl/scripts/ci/runner-watch-install.ps1" ]; then
        rwh=$(gh api "repos/{owner}/{repo}/actions/variables/RUNNER_WATCH_HOSTED" --jq .value 2>/dev/null) || rwh=""
        [ "$rwh" = yes ] || echo "  watch:    the runner watch runs on the runners' machine now, not hosted. Once, on that machine: powershell -ExecutionPolicy Bypass -File scripts\\ci\\runner-watch-install.ps1 (cron elsewhere). To keep the hosted copy as well, which alone can say the whole machine is off: gh variable set RUNNER_WATCH_HOSTED --body yes"
      fi
    fi ;;
esac
if command -v gh >/dev/null 2>&1 && gh api "repos/{owner}/{repo}/actions/variables/DEPLOY_JOBS_ON" >/dev/null 2>&1; then
  echo "  deploy:   the repository variable DEPLOY_JOBS_ON is no longer read; Deploy's plan runs where ci.yml's jobs run. Remove it: gh variable delete DEPLOY_JOBS_ON"
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
# A workflow is built in memory, filled with the project's runner and shell
# (read above), and written only when nothing is left unfilled and every
# script it runs is here or written now; otherwise it is refused and said.
written=""
for p in $changed $missing $defaults; do
  if [ "$force" = no ]; then
    case " $edited " in *" $p "*) echo "  kept:     $p (edited here; pass --force to replace it)"; continue ;; esac
  fi
  case "$p" in
    .github/workflows/*.yml)
      case " $refused " in *" $p "*) continue ;; esac
      w_text=$(filled_text "$(cat "$tpl/$p")" "$runs_on" "$run_shell")
      mkdir -p "$(dirname "$p")"
      printf '%s\n' "$w_text" > "$p"
      if [ -n "$runs_on" ] && grep -qw 'RUNS_ON' "$tpl/$p"; then echo "  filled:   RUNS_ON in $p from ci.yml ($runs_on)"; fi
      if [ -n "$run_shell" ] && grep -qw 'RUN_SHELL' "$tpl/$p"; then echo "  filled:   RUN_SHELL in $p from ci.yml"; fi
      needs=$(workflow_needs "$w_text")
      [ -n "$needs" ] && echo "  needs:    $p reads $needs; set them in the repository before its first run" ;;
    *)
      mkdir -p "$(dirname "$p")"
      cp "$tpl/$p" "$p"
      case "$p" in *.sh) chmod +x "$p" 2>/dev/null || true ;; esac
      if [ "$p" = .claude/numbering.txt ]; then
        . "$tpl/scripts/ci/numbering-lib.sh"
        g=$(migration_glob_guess "$(git ls-files 2>/dev/null)")
        if [ -n "$g" ]; then
          awk -v g="$g" '/^migration[ 	]/ && !done { print "migration " g; done = 1; next } { print }' "$p" > "$p.tmp" && mv "$p.tmp" "$p"
          echo "  numbering: migrations are in $g here; .claude/numbering.txt says so"
        fi
      fi ;;
  esac
  written="$written $p"
done
[ -n "$(printf '%s' "$written" | tr -d ' ')" ] || { echo "Nothing written: every differing file was edited here or refused above."; git checkout -q -; exit 0; }
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
