#!/bin/sh
# Record a step held until another pull request lands, on the pull request
# that waits, so the wait is a fact the queue reads and not something an
# agent has to remember (scripts/ci/QUEUE.md, "Held steps"). A merge of main
# once waited an hour past the landing it was waiting for, with every runner
# idle and nothing on the dashboard saying why.
#
# Usage: sh scripts/ci/wait-for.sh PR AFTER [STEP] [SESSION]
#   PR       the pull request that waits
#   AFTER    the pull request it waits for
#   STEP     "merge-main" (the default: the queue merges main into PR itself
#            once AFTER lands, at a drain's end with no other CI running),
#            or the step in plain words, which the session takes; the
#            drain's report and the session brief then name the session
#   SESSION  the waiting session's name, so the report can wake it
# Posts one comment with a hidden merge-queue:after mark and adds the
# queue:after label, both through REST. The drain's end marks the wait done
# when it acts on it, and the label goes when nothing waits on PR any more.
set -e
here=$(dirname "$0")
. "$here/batch-lib.sh"
pr=$1; after=$2; step=${3:-merge-main}; session=${4:--}
case "$pr:$after" in :*|*:|*[!0-9:]*) echo "Usage: sh scripts/ci/wait-for.sh PR AFTER [merge-main|\"the step in words\"] [SESSION]" >&2; exit 2 ;; esac
kind=$(after_step "$step")
if [ "$kind" = merge-main ]; then words="merge main in"; then_say="the merge queue merges main into this pull request by itself, at a drain's end with no other CI running"
else words=$step; then_say="the merge queue's report and the session brief name the session that takes it"; fi
title=$(gh api "repos/{owner}/{repo}/pulls/$after" --jq .title 2>/dev/null | tr -d '\r' || true)
body=$(printf 'Waiting for #%s%s to land, then: %s. When it lands, %s.\n\n%s' "$after" "${title:+ ($title)}" "$words" "$then_say" "$(after_mark "$after" "$kind" "$session" "$words")")
gh api -X POST "repos/{owner}/{repo}/issues/$pr/comments" -f body="$body" > /dev/null
gh api -X POST "repos/{owner}/{repo}/issues/$pr/labels" -f 'labels[]=queue:after' > /dev/null
echo "Recorded on #$pr: waits for #$after, then $words."
