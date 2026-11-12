#!/bin/sh
# The words the queue prints about what it did, kept apart so the big files
# do not grow: the rule behind a skipped deploy, a pull request found already
# on main, and a change a drain lands after saying nothing was green yet.
# Sourced by scripts/ci/merge-queue.sh; functions only.

# skip_rule_said: the rule the deploy gate applied, from .claude/deploy.json,
# so a wrong skip is seen in the log.
skip_rule_said() {
  # The JSON helpers live in deploy-lib.sh, which merge-queue.sh does not
  # source: a skipped deploy once printed an empty rule for want of them.
  command -v json_string >/dev/null 2>&1 && command -v json_words >/dev/null 2>&1 || . "${here:-$(dirname "$0")}/deploy-lib.sh"
  sk_cfg=$(cat .claude/deploy.json 2>/dev/null || true)
  sk_app=$(json_string "$sk_cfg" appRoot); sk_app=${sk_app:-.}
  sk_never=$(json_words "$sk_cfg" neverShips); sk_also=$(json_words "$sk_cfg" alsoShips)
  printf 'rule: only %s ships%s%s; docs, specs, tests, design, the plugin scripts and Markdown never do' "$sk_app" "${sk_never:+, except $sk_never}" "${sk_also:+, plus $sk_also}"
}

# pr_already_merged PR: "yes" when GitHub says the pull request is merged.
pr_already_merged() {
  if [ "$(gh api "repos/{owner}/{repo}/pulls/$1" --jq .merged 2>/dev/null | tr -d '\r')" = true ]; then echo yes; else echo no; fi
}

# late_wait_note ROUND: the drain said nothing new was green in this round;
# remember the first such round, so a later landing can say it was waiting.
late_wait_note() {
  mkdir -p "$flaky_dir" 2>/dev/null || true
  [ -s "$flaky_dir/waited-round" ] || printf '%s\n' "$1" > "$flaky_dir/waited-round" 2>/dev/null || true
}

# late_lands_say ROUND PICK: when the round lands pull requests after
# "nothing new is green", name them and the round that waited.
late_lands_say() {
  ll_was=$(cat "$flaky_dir/waited-round" 2>/dev/null | tr -d '\r\n ')
  [ -n "$ll_was" ] || return 0
  for ll_pr in $2; do
    say "round $1: landing #$ll_pr, $(pr_field "$ll_pr" 3), which was still running CI in round $ll_was and has turned green."
  done
  rm -f "$flaky_dir/waited-round" 2>/dev/null || true
}
