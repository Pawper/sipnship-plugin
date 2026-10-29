#!/bin/sh
# The design check, in one CI step: the generated design files are current,
# no UI file gained a literal colour, size or font, and every screen pair
# the change touches references the same type roles on both platforms.
# Usage: sh scripts/ci/design-check.sh BASE HEAD      (CI; SPEC_TEXT or
#        PR_TEXT holds the pull request title and body)
#    or: sh scripts/ci/design-check.sh                (the working tree
#        against origin/main, by hand)
# Config: scripts/ci/design-ui.txt lists the UI file globs the literal
# check reads (default: src/**/*.tsx, *.css, android **/*.kt, ios **/*.swift);
# scripts/ci/design-allow.txt holds one regex per line of lines to allow.
# A literal that must stay says why in the body: "Design: <reason>".
# Where design/copy/ exists, the copy files must be current against the
# mocks and a UI file may not gain words as a literal; scripts/ci/
# copy-allow.txt names the user-facing calls and the literals allowed.
# Each step says when it starts, so a long run is visibly a slow step and
# not a hang, and the whole check gives up after DESIGN_CHECK_SECONDS
# (default 90), naming the step it was in.
here=$(dirname "$0")
. "$here/../design/design-lib.sh"
[ -f design/tokens.json ] || { echo "No design/tokens.json; nothing to check."; exit 0; }

budget=${DESIGN_CHECK_SECONDS:-90}
step="starting"
step() { step=$1; echo "design-check: $1"; }
# The watchdog sleeps a second at a time, so ending it leaves nothing behind.
( i=0; while [ "$i" -lt "$budget" ]; do sleep 1; i=$((i + 1)); done; kill -TERM $$ 2>/dev/null ) &
watchdog=$!
trap 'echo "design-check.sh gave up after ${budget}s during: $step (DESIGN_CHECK_SECONDS raises the budget)" >&2; kill "$watchdog" 2>/dev/null; exit 1' TERM
done_check() { kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null; }

fail=0
# 0. copy files current against the mocks, only where design/copy/ exists
if [ -d design/copy ]; then
  step "copy files current against the mocks (node scripts/design/copy-extract.mjs --check)"
  if [ ! -f scripts/design/copy-extract.mjs ]; then
    echo "No scripts/design/copy-extract.mjs here, so design/copy/ was not checked against the mocks." >&2
  elif command -v node >/dev/null 2>&1; then
    node scripts/design/copy-extract.mjs --check || fail=1
  else
    echo "node is not on the PATH, so design/copy/ was not checked against the mocks." >&2
  fi
fi

# 1. generated files current
step "generated files current (node scripts/design/generate.mjs --check)"
if [ ! -f scripts/design/generate.mjs ]; then
  echo "No scripts/design/generate.mjs here, so the generated design files were not checked." >&2
elif command -v node >/dev/null 2>&1; then
  node scripts/design/generate.mjs --check || fail=1
else
  echo "node is not on the PATH, so the generated design files were not checked." >&2
fi

base=${1:-origin/main}; head=${2:-}
# A pull request is judged on its own lines only. When HEAD is the merge of
# the branch into main as it is now (two parents), the base is that merge's
# first parent, whatever was passed: a recorded base.sha is main as it was
# when the pull request last moved, and a line that landed on main since
# then was once flagged as the pull request's.
if [ -n "$head" ] && git rev-parse -q --verify "$head^2" >/dev/null 2>&1; then
  base=$(git rev-parse "$head^1")
elif [ -n "$head" ]; then
  # Not a merge commit (a branch tip, a push): diff from where the branch
  # left main, so main's own later changes are never the pull request's.
  mb=$(git merge-base "$base" "$head" 2>/dev/null) && base=$mb
fi
if [ -n "$head" ]; then range="$base $head"; diff_args="$base $head"; else range="$base"; diff_args="$base"; fi

# 2. literals in UI files
step "literals added to UI files (git diff $range over scripts/ci/design-ui.txt)"
ui_globs=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' scripts/ci/design-ui.txt 2>/dev/null)
[ -n "$ui_globs" ] || ui_globs='src/**/*.tsx
src/**/*.ts
src/**/*.css
android/**/*.kt
ios/**/*.swift'
allow=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' scripts/ci/design-allow.txt 2>/dev/null | paste -sd'|' -)
# the generated files, the token source and the fonts are never literals
gen=$(node -e 'const o=require(process.cwd()+"/design/tokens.json").outputs||{};console.log([o.ts,o.css,o.kotlin&&o.kotlin.path,typeof o.swift=="string"?o.swift:o.swift&&o.swift.path,o.copyTs,o.copyKotlin&&o.copyKotlin.path,typeof o.copySwift=="string"?o.copySwift:o.copySwift&&o.copySwift.path].filter(Boolean).join("\n"))' 2>/dev/null)
excl=$(printf '%s\n' "$gen" | sed '/^$/d; s/^/:(exclude)/')
# The globs go to git whole: with shell globbing on, src/**/*.tsx expanded
# two levels deep and no deeper file was ever checked (531 lines seen of
# 1276 on one project). git's pathspec reads * across folders.
set -f
# shellcheck disable=SC2086
ui_diff=$(git diff -U0 $diff_args -- $ui_globs ':(exclude)design/**' ':(exclude)**/node_modules/**' ':(exclude)**/build/**' $excl 2>/dev/null)
set +f
fonts=$(token_font_names "$(cat design/tokens.json)")
hits=$(design_literals "$ui_diff" "$fonts" "${allow:-}")
if [ -n "$hits" ]; then
  why=$(design_escape "${SPEC_TEXT:-${PR_TEXT:-}}")
  if [ -n "$why" ]; then
    echo "Literal values added to UI files, allowed by the pull request: Design: $why"
    printf '%s\n' "$hits" | sed 's/^/  /'
  else
    echo "A screen uses a token or a type role by name, never a literal colour, size or font. These lines add one:" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    echo "Move the value into design/tokens.json and regenerate, use the role's class or object, or say why it must stay with a line \"Design: <reason>\" in the pull request body." >&2
    fail=1
  fi
fi

# 2a. token names the generated design file does not define
css_gen=$(node -e 'const o=require(process.cwd()+"/design/tokens.json").outputs||{};console.log(o.css||"")' 2>/dev/null)
if [ -n "$css_gen" ] && [ -f "$css_gen" ]; then
  step "token names added to UI files that $css_gen does not define"
  # Names a UI file sets itself (a style attribute, a local custom
  # property) are defined too.
  set -f
  # shellcheck disable=SC2086
  ui_files=$(git ls-files -- $ui_globs ':(exclude)**/node_modules/**' 2>/dev/null)
  set +f
  defined=$( { cat "$css_gen"; for uf in $ui_files; do cat "$uf" 2>/dev/null; done; } )
  gaps=$(css_var_gaps "$ui_diff" "$(css_var_names "$defined")")
  if [ -n "$gaps" ]; then
    echo "These lines read a token name that $css_gen does not define, so the value resolves to nothing:" >&2
    printf '%s\n' "$gaps" | sed 's/^/  /' >&2
    echo "Use the name as the generated file spells it (it keeps the name design/tokens.json gives the token), or add the token to design/tokens.json and regenerate." >&2
    fail=1
  fi
fi

# 2b. words added to UI files as literals, only where design/copy/ exists
if [ -d design/copy ]; then
  step "words added to UI files as literals (scripts/ci/copy-allow.txt)"
  callow=$(cat scripts/ci/copy-allow.txt 2>/dev/null)
  cl_re=$(copy_section "$callow" "allowed literals" | paste -sd'|' -)
  chits=$(copy_literals "$ui_diff" "$(copy_section "$callow" "user-facing calls")" "$cl_re")
  if [ -n "$chits" ]; then
    why=$(design_escape "${SPEC_TEXT:-${PR_TEXT:-}}")
    if [ -n "$why" ]; then
      echo "Words added to UI files as literals, allowed by the pull request: Design: $why"
      printf '%s\n' "$chits" | sed 's/^/  /'
    else
      echo "A screen says its words through the copy module (copy.<screen>.<id>), generated from the mocks, never as a literal. These lines add one:" >&2
      printf '%s\n' "$chits" | sed 's/^/  /' >&2
      echo "Put the words in the mock, run node scripts/design/copy-extract.mjs and node scripts/design/generate.mjs, and use the generated id; add a literal that is not words to the allowed literals in scripts/ci/copy-allow.txt; or say why it must stay with a line \"Design: <reason>\" in the pull request body." >&2
      fail=1
    fi
  fi
fi

# 3. role parity per screen pair the change touches
if [ -f scripts/ci/parity.txt ]; then
  step "role parity per screen pair the change touches (scripts/ci/parity.txt)"
  keys=$(token_role_keys "$(cat design/tokens.json)")
  # shellcheck disable=SC2086
  changed=$(git diff --name-only $diff_args -- . ':(exclude)**/node_modules/**' ':(exclude)**/build/**' 2>/dev/null)
  # A side is a file, or a folder (ending in "/"): every file under it.
  # Roles at a revision: REV empty reads the working tree.
  file_roles_at() {
    fr_rev=$2
    fr_list=$(git ls-tree -r --name-only "${fr_rev:-HEAD}" 2>/dev/null)
    for fr_f in $(side_files "$1" "$fr_list"); do
      if [ -n "$fr_rev" ]; then role_refs "$(git show "$fr_rev:$fr_f" 2>/dev/null)" "$keys"
      else role_refs "$(cat "$fr_f" 2>/dev/null)" "$keys"; fi
    done | sort -u
  }
  base_rev=$(git merge-base "$base" "${head:-HEAD}" 2>/dev/null || true)
  # A file several pairs name (a native screen holding many web blocks) is
  # compared with the union of its partners' roles, once.
  mism=$(parity_groups "$(parity_pairs "$(cat scripts/ci/parity.txt)")" | while IFS="$(printf '\t')" read -r f partners; do
    touched=no
    for x in $f $partners; do
      if [ "$(side_touched "$x" "$changed")" = yes ]; then touched=yes; fi
    done
    [ "$touched" = yes ] || continue
    np=$(printf '%s\n' $partners | wc -l | tr -d ' ')
    if [ "$np" -gt 1 ]; then side="the $np files paired with it"; else
      case "$partners" in */) side="$partners" ;; *) side=$(basename "$partners") ;; esac
    fi
    case "$f" in */) fname=$f ;; *) fname=$(basename "$f") ;; esac
    # Only what this change adds: the pair's mismatches after it, less
    # those it already had before. A gap that predates the change passes.
    after=$(role_mismatch "$fname" "$fname" "$(file_roles_at "$f" "$head")" "$side" "$(for x in $partners; do file_roles_at "$x" "$head"; done | sort -u)")
    before=""
    if [ -n "$base_rev" ]; then
      before=$(role_mismatch "$fname" "$fname" "$(file_roles_at "$f" "$base_rev")" "$side" "$(for x in $partners; do file_roles_at "$x" "$base_rev"; done | sort -u)")
    fi
    new_lines "$before" "$after"
  done)
  if [ -n "$mism" ]; then
    echo "This change makes a screen pair reference different type roles on its two platforms:" >&2
    printf '%s\n' "$mism" | sed 's/^/  /' >&2
    echo "Give both sides the same roles (the role is the unit; its size lives in design/tokens.json), or name the open issue that brings the other side along in a \"Parity: #N\" line." >&2
    if [ -n "$(design_escape "${SPEC_TEXT:-${PR_TEXT:-}}")" ] || printf '%s\n' "${SPEC_TEXT:-${PR_TEXT:-}}" | grep -qiE '^[[:space:]]*parity:'; then
      echo "  (allowed by the pull request's Design: or Parity: line)"
    else fail=1; fi
  fi
fi

# 4. a file under a screen folder that no pair lists
if [ -f scripts/ci/parity.txt ]; then
  step "files under a paired screen folder that no pair lists"
  # shellcheck disable=SC2086
  unp=$(parity_unpaired "$(git diff --name-only --diff-filter=AM $diff_args -- . ':(exclude)**/node_modules/**' ':(exclude)**/build/**' 2>/dev/null)" "$(cat scripts/ci/parity.txt)")
  if [ -n "$unp" ]; then
    echo "These files sit in a folder that scripts/ci/parity.txt pairs across platforms, but are in no pair themselves:" >&2
    printf '%s\n' "$unp" | sed 's/^/  /' >&2
    echo "Add each to a pair (NAME PATH_A PATH_B), or declare it one-sided with a line \"unpaired PATH\" in parity.txt." >&2
    if [ -n "$(design_escape "${SPEC_TEXT:-${PR_TEXT:-}}")" ] || printf '%s\n' "${SPEC_TEXT:-${PR_TEXT:-}}" | grep -qiE '^[[:space:]]*parity:'; then
      echo "  (allowed by the pull request's Design: or Parity: line)"
    else fail=1; fi
  fi
fi

done_check
[ "$fail" -eq 0 ] && echo "Design check passed."
exit $fail
