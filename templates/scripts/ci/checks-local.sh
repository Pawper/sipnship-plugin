#!/bin/sh
# The quick checks before a push leaves the machine: the steps of the
# "checks" job in .github/workflows/ci.yml that run one of the project's
# own scripts (sh scripts/... or sh status/...), read from ci.yml itself so
# the two never drift. A size or mock failure is then seen in seconds here,
# not after a CI run. Each failure is printed in the check's own words.
#
# Usage: sh scripts/ci/checks-local.sh [BASE [HEAD]]
#   BASE defaults to where HEAD left origin/main (no fetch: nothing here
#   goes to the network but the one REST read of the pull request body),
#   HEAD to the commit checked out.
#
# The steps that read the pull request's body (Spec:, Mock:, Design:,
# Parity:, Deletes:) take it from .scratch/body.md when it is there, else
# from the open pull request for this branch over REST; with neither, they
# say so and are skipped, and every other step still runs.
# CHECKS_LOCAL_BODY names another body file; CHECKS_LOCAL_OFFLINE=1 skips
# the REST read. The steps run side by side; the whole run gives up after
# CHECKS_LOCAL_SECONDS (default 60).
# Exit: 0 when every step that ran passed, 1 when one failed.
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "checks-local: not inside a git repository." >&2; exit 1; }
cd "$top" || exit 1
wf=.github/workflows/ci.yml
[ -f "$wf" ] || { echo "checks-local: no $wf here; nothing to run."; exit 0; }
start=$(date +%s)

head=${2:-HEAD}
head=$(git rev-parse --verify -q "$head^{commit}") || { echo "checks-local: cannot read the commit $2." >&2; exit 1; }
if [ -n "${1:-}" ]; then base=$1
else
  base=""
  for ref in origin/main origin/master main master; do
    git rev-parse -q --verify "$ref" >/dev/null 2>&1 || continue
    base=$(git merge-base "$ref" "$head" 2>/dev/null) && break
  done
  [ -n "$base" ] || base="$head~1"
fi

# The pull request's title and body, when one can be read.
body_file=${CHECKS_LOCAL_BODY:-.scratch/body.md}
body_from=""
if [ -f "$body_file" ]; then
  pr_text=$(cat "$body_file"); pr_body=$pr_text; body_from=$body_file
elif [ "${CHECKS_LOCAL_OFFLINE:-0}" != 1 ] && command -v gh >/dev/null 2>&1; then
  branch=$(git symbolic-ref -q --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    # The owner from the remote's address, which saves a call; else asked.
    owner=$(git remote get-url origin 2>/dev/null | sed -n 's#.*github\.com[:/]\([^/]*\)/.*#\1#p')
    [ -n "$owner" ] || owner=$(gh api "repos/{owner}/{repo}" --jq '.owner.login' 2>/dev/null)
    if [ -n "$owner" ]; then
      got=$(gh api "repos/{owner}/{repo}/pulls?state=open&head=$owner:$branch" --jq 'if length > 0 then "found\n" + .[0].title + "\n" + (.[0].body // "") else "" end' 2>/dev/null)
      case "$got" in found*)
        pr_text=$(printf '%s\n' "$got" | sed 1d)
        pr_body=$(printf '%s\n' "$pr_text" | sed 1d)
        body_from="the open pull request" ;;
      esac
    fi
  fi
fi

# The classes of the change, for a step's "contains(steps.classes...)".
classes=$(sh scripts/ci/classify.sh "$base" "$head" 2>/dev/null)

# One record per step of the checks job, fields split by the unit
# separator (an empty "if" must keep its place): S name if - body, then
# C command for each "sh ..." line of its run block.
steps=$(awk '
  function flush() {
    if (inst && !uses && id != "classes") {
      printf "S\037%s\037%s\037-\037%s\n", name, cond, body
      for (i = 1; i <= nc; i++) printf "C\037%s\n", cmd[i]
    }
    inst = 0; name = ""; cond = ""; id = ""; uses = 0; body = 0; nc = 0; inrun = 0
  }
  /^  [A-Za-z_-]+:/ { if (injob) { flush(); injob = 0 } ; if ($0 ~ /^  checks:/) injob = 1; next }
  !injob { next }
  /^      - / { flush(); inst = 1; line = $0; sub(/^      - /, "        ", line); $0 = line }
  !inst { next }
  {
    if (match($0, /^        [A-Za-z_-]+:/)) {
      inrun = 0
      key = $0; sub(/^ +/, "", key); val = key; sub(/:.*/, "", key); sub(/^[^:]*:[ ]*/, "", val)
      if (key == "name") name = val
      else if (key == "if") cond = val
      else if (key == "id") id = val
      else if (key == "uses") uses = 1
      else if (key == "run") { if (val == "|" || val == "|-" || val == ">") inrun = 1; else cmd[++nc] = val }
    } else if (inrun) {
      l = $0; sub(/^ +/, "", l)
      if (l ~ /^sh [^ ]+\.sh/) cmd[++nc] = l
    }
    if ($0 ~ /pull_request\.(body|title)|SPEC_TEXT|PR_TEXT|PR_BODY/) body = 1
  }
  END { if (injob) flush() }
' "$wf")

# cond_holds IF: whether a step's "if:" holds here. A pull request event,
# the classes above and the files present; failure() and the like never
# hold; anything else unread runs the step, the safe side.
cond_holds() {
  ch=$(printf '%s' "$1" | sed 's/^\${{ *//; s/ *}}$//')
  [ -n "$ch" ] || return 0
  case "$ch" in *'failure()'*|*'cancelled()'*|*'always()'*|*'success()'*) return 1 ;; esac
  ch=$(printf '%s\n' "$ch" | CLASSES=" $classes " awk '{
    s = $0
    gsub(/github\.event_name *== *'"'"'pull_request'"'"'/, "1", s)
    gsub(/github\.event_name *!= *'"'"'pull_request'"'"'/, "0", s)
    while (match(s, /contains\(steps\.classes\.outputs\.classes, *'"'"'[^'"'"']*'"'"'\)/)) {
      t = substr(s, RSTART, RLENGTH); c = t; sub(/^[^'"'"']*'"'"'/, "", c); sub(/'"'"'.*/, "", c)
      v = (index(ENVIRON["CLASSES"], c) > 0) ? "1" : "0"
      s = substr(s, 1, RSTART - 1) v substr(s, RSTART + RLENGTH)
    }
    while (match(s, /hashFiles\('"'"'[^'"'"']*'"'"'\) *(!=|==) *'"'"''"'"'/)) {
      t = substr(s, RSTART, RLENGTH); p = t; sub(/^hashFiles\('"'"'/, "", p); sub(/'"'"'.*/, "", p)
      e = (system("test -e \"" p "\"") == 0)
      v = (t ~ /!=/) ? (e ? "1" : "0") : (e ? "0" : "1")
      s = substr(s, 1, RSTART - 1) v substr(s, RSTART + RLENGTH)
    }
    print s }')
  case "$ch" in *[!01\ \(\)\&\|!]*) return 0 ;; esac
  [ "$(( ch ))" -ne 0 ]
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/checks-local.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM HUP
export BASE="$base" CHECKS_HEAD="$head"
if [ -n "$body_from" ]; then
  SPEC_TEXT=$pr_text; PR_TEXT=$pr_text; PR_BODY=$pr_body
  export SPEC_TEXT PR_TEXT PR_BODY
else
  unset SPEC_TEXT PR_TEXT PR_BODY
fi
# No pull request number: the checks then make no network call of their
# own (no overlap read, no comment), and judge only this change.
unset GH_TOKEN

n=0; skipped=""
pids=""
run_step() {
  rs_n=$1; rs_name=$2; rs_cmds=$3
  printf '%s\n' "$rs_name" > "$tmp/$rs_n.name"
  (
    rc=0
    printf '%s\n' "$rs_cmds" | while IFS= read -r c; do
      [ -n "$c" ] || continue
      eval "$c" < /dev/null || exit 1
    done || rc=1
    echo "$rc" > "$tmp/$rs_n.rc"
  ) > "$tmp/$rs_n.out" 2>&1 < /dev/null &
  pids="$pids $!"
}

name=""; cond=""; nbody=0; cmds=""
launch() {
  [ -n "$name" ] || return 0
  if [ -z "$cmds" ]; then :
  elif ! cond_holds "$cond"; then :
  elif [ "$nbody" = 1 ] && [ -z "$body_from" ]; then
    skipped="$skipped
  - $name"
  else
    n=$((n + 1)); run_step "$n" "$name" "$cmds"
  fi
  name=""; cmds=""
}
us=$(printf '\037')
while IFS="$us" read -r kind a b c d; do
  case "$kind" in
    S) launch; name=$a; cond=$b; nbody=$d ;;
    C)
      cl=$(printf '%s' "$a" | sed 's/\${{ *github\.sha *}}/$CHECKS_HEAD/g; s/"\${{ *github\.event\.pull_request\.number *}}"/""/g')
      case "$cl" in
        *'${{'*) skipped="$skipped
  - $name (it needs GitHub's own context)"; name="" ;;
        # Only the project's own scripts that are here.
        *) if [ -f "$(printf '%s' "${cl#sh }" | cut -d' ' -f1)" ]; then cmds="$cmds$cl
"; fi ;;
      esac ;;
  esac
done <<EOF
$steps
EOF
launch

# Wait for every step, within the budget.
budget=${CHECKS_LOCAL_SECONDS:-60}
( s=0; while [ "$s" -lt "$budget" ]; do sleep 1; s=$((s + 1)); done; for p in $pids; do kill "$p" 2>/dev/null; done ) &
watchdog=$!
for p in $pids; do wait "$p" 2>/dev/null; done
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null

failed=0; i=1
while [ "$i" -le "$n" ]; do
  rc=$(cat "$tmp/$i.rc" 2>/dev/null || echo timeout)
  if [ "$rc" != 0 ]; then
    failed=$((failed + 1))
    if [ "$rc" = timeout ]; then
      printf 'Failed: %s (still running after %ss; CHECKS_LOCAL_SECONDS raises the budget)\n' "$(cat "$tmp/$i.name")" "$budget"
    else
      printf 'Failed: %s\n' "$(cat "$tmp/$i.name")"
    fi
    grep -v '^::warning::' "$tmp/$i.out" | sed 's/^/  /'
  fi
  i=$((i + 1))
done
took=$(( $(date +%s) - start ))
if [ -n "$skipped" ]; then
  if [ -z "$body_from" ]; then
    printf 'Not run here, because no pull request body was found (write it to %s, or open the pull request):%s\n' "$body_file" "$skipped"
  else
    printf 'Not run here:%s\n' "$skipped"
  fi
fi
if [ "$failed" -gt 0 ]; then
  printf '%s of %s quick checks failed (%ss). CI runs the same steps and would fail them too.\n' "$failed" "$n" "$took"
  exit 1
fi
printf 'Quick checks passed: %s steps in %ss.\n' "$n" "$took"
