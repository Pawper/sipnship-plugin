#!/bin/sh
# The session brief's one line about the live app (spec 014): whether it
# works, and the problem's sentence while it does not. Read from the latest
# Live run that looked at the app: the run sends its findings as one notice
# titled "Your live app", and a run that was not a moment to look has none, so
# the newest few runs are walked. Slow (a few REST calls), so it is run by
# session-brief-slow.sh in the background into a cache.
#
# Usage: sh session-brief-live.sh
# Prints one line, "Live app: ...", or nothing when no run has looked yet.
# Fails soft; nothing here prints a token.

LIVE_STEP="Look at the live app"
LIVE_TITLE="Your live app"
LIVE_RUNS=8

# live_app_line MESSAGE
# One line from the notice's message: collapsed to single spaces and kept
# short. Nothing for an empty message.
live_app_line() {
  lal=$(printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$lal" ] || return 0
  [ "${#lal}" -le 280 ] || lal="$(printf '%s' "$lal" | cut -c1-277)..."
  printf 'Live app: %s\n' "$lal"
}

live_app_read() {
  command -v gh >/dev/null 2>&1 || return 0
  runs=$(gh api "repos/{owner}/{repo}/actions/workflows/live.yml/runs?status=completed&per_page=$LIVE_RUNS" --jq '.workflow_runs[].id' 2>/dev/null) || return 0
  for run in $runs; do
    job=$(gh api "repos/{owner}/{repo}/actions/runs/$run/jobs" --jq ".jobs[0] | select(any(.steps[]?; .name == \"$LIVE_STEP\" and .conclusion == \"success\")) | .id" 2>/dev/null) || continue
    [ -n "$job" ] || continue
    msg=$(gh api "repos/{owner}/{repo}/check-runs/$job/annotations" --jq "[.[] | select(.title == \"$LIVE_TITLE\")][0].message // empty" 2>/dev/null) || continue
    [ -n "$msg" ] || continue
    live_app_line "$msg"
    return 0
  done
  return 0
}

# Run as a script; sourced, only the functions are defined.
case "${0##*/}" in session-brief-live.sh) live_app_read ;; esac
