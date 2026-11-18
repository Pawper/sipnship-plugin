#!/bin/sh
# Sourced by the scripts that run unattended (the plan, the queue, the
# template sync, the brief). A git that has no bound of its own can run for
# a day if what it reads is huge or what feeds it has gone, and on Windows a
# shell that is stopped does not stop the git under it. So every unattended
# git is the direct child of `timeout`, which ends that git itself, whatever
# became of its callers.
#
# gitb ARGS...                  git ARGS, ended after GIT_BOUND_SECONDS (default 120)
# git_bounded SECONDS ARGS...   the same with a bound of its own
# A git that was ended returns 124, as timeout does; callers that can go on
# without the answer already end their line with `|| true`. Without a
# timeout command git runs as it was.
gitb() {
  if command -v timeout >/dev/null 2>&1; then timeout -k 5 "${GIT_BOUND_SECONDS:-120}" git "$@"; else git "$@"; fi
}
git_bounded() {
  gb_secs=$1; shift
  GIT_BOUND_SECONDS=$gb_secs gitb "$@"
}
