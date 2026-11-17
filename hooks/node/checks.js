'use strict';
// The checks before a Bash call, one function each, in the order hooks.json
// runs them. A check returns null to let the call through, or the words to
// refuse it with (what the shell hook printed to stderr before exit 2). The
// words are copied from the shell hooks; the proof that they are the same
// is tests/run.sh, block "hooks in node: the same verdicts and words".
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { jsonField, shellValue, splitCommands, words } = require('./text');
const R = require('./reasons');
const { budgetRead, budgetLine, budgetLow } = require('./budget');
const { ruleOn, ruleOffNote } = require('./logs');

// gate(ctx, id): for a check that has found something to refuse: true when the
// rule is on; when it is off, notes that the call went through and says no.
function gate(ctx, id) {
  if (ruleOn(id)) return true;
  ruleOffNote(ctx.name, id, ctx.session);
  return false;
}

function ruleSwitch(ctx) {
  let hit;
  if (ctx.cmd) {
    hit = R.ruleSwitchReason(ctx.cmd);
  } else {
    const p = jsonField(ctx.input, 'file_path');
    if (!p) return null;
    hit = R.ruleSwitchPathReason(p);
  }
  if (!hit) return null;
  return "Blocked `" + hit + "` because a rule's switch is the builder's to turn, never an agent's: an agent that switched its own rule off would be marking its own work. If a rule is in your way, say which and why in your report, and the person can switch it on the Rules tab or with `sh scripts/rules.sh off ID \"reason\"` in their own terminal.";
}

function looseEnds(ctx) {
  if (!ctx.cmd) return null;
  const desc = shellValue(jsonField(ctx.input, 'description'));
  let longHit = R.longCommandReason(ctx.cmd, desc);
  if (longHit && !ruleOn('shell-says-what')) { ruleOffNote(ctx.name, 'shell-says-what', ctx.session); longHit = ''; }
  if (longHit === 'no description') {
    return 'Blocked a Bash call with no description: the task window shows the raw command instead of a title. The command itself is fine; call it again with the Bash tool\'s `description` field set to a few words saying what it does.';
  }
  if (longHit) {
    return 'Blocked a Bash call of ' + longHit + ' of code (quoted text is not counted), because a program pasted into the command fills the task window with its source and has no name; write it to .scratch/NAME.sh (or .py) with the Write tool, run it as `sh .scratch/NAME.sh`, and give the call a one-line description. A long pull request or issue body goes in a file: `-F body=@.scratch/body.md`.';
  }
  let hit = R.prCloseReason(ctx.cmd);
  if (hit && !ruleOn('work-has-ending')) { ruleOffNote(ctx.name, 'work-has-ending', ctx.session); hit = ''; }
  if (hit) {
    return 'Blocked `gh pr close` because a closed pull request needs an ending; add `--comment` saying why or what replaced it, or run `sh scripts/worktrees.sh close PR "reason"`, which also archives the branch and removes its worktree.';
  }
  hit = R.stdinWaitReason(ctx.cmd);
  if (hit) {
    return 'Blocked `' + hit + '` because it reads input that never comes and would hang the shell; give it a file to read, pipe something into it, or use a heredoc (`cat > file <<\'EOF\'`).';
  }
  hit = R.worktreeAddReason(ctx.cmd);
  if (hit && !ruleOn('work-has-ending')) { ruleOffNote(ctx.name, 'work-has-ending', ctx.session); hit = ''; }
  if (hit) {
    return 'Blocked a detached worktree because its commits would be reachable only from that folder; add it with a branch instead, for example `git worktree add -b task-name path`.';
  }
  hit = R.daemonStopReason(ctx.cmd);
  if (hit) {
    return 'Blocked `' + hit + '` because the build daemon is shared by every build on this machine, including a self-hosted runner\'s job in flight, which fails with "daemon has been stopped". Let it idle out; stopping what you started means your own servers and watchers, not the daemon. If no runner runs on this machine, prefix the command with DAEMON_STOP_OK=1.';
  }
  return null;
}

function blockDelete(ctx) {
  if (!ctx.cmd) return null;
  const hit = R.deleteReason(ctx.cmd);
  if (!hit || !gate(ctx, 'never-delete')) return null;
  return 'Blocked `' + hit + '` because this project never deletes files; move them aside instead, for example `git mv path aside/path` or `mv path path.aside`.';
}

function blockForcePush(ctx) {
  if (!ctx.cmd) return null;
  const hit = R.forcePushReason(ctx.cmd);
  if (!hit || !gate(ctx, 'never-force-push')) return null;
  return 'Blocked the forced push (`' + hit + '`) because shared history is never rewritten; push a new commit on top, or start a new branch if this one is wrong.';
}

function fullTestSweep(ctx) {
  if (!ctx.cmd) return null;
  const hit = R.fullSweepReason(ctx.cmd);
  if (!hit || !gate(ctx, 'tests-one-file')) return null;
  const example = /^(npm|yarn|pnpm|bun)/.test(hit) ? hit + ' -- path/to/one_test' : hit + ' path/to/one_test';
  return 'Blocked the full test sweep `' + hit + '` because it names no test file, and the whole suite runs on main in CI; name the file for the change you made, for example `' + example + '` (any .test or .spec file in .ts, .tsx, .js, .jsx, .mjs or .cjs is fine, as is a -k, -t or --filter pattern).';
}

// The ask reader stays in shell (templates/scripts/ci/ask-lib.sh, shared with
// the nightly audit): it runs only when a command sets an issue to waiting on
// the owner, which is rare, and prints what is wrong with the ask, or nothing.
function askFix(issue) {
  const hooks = path.join(__dirname, '..', 'scripts');
  const askLib = path.join(__dirname, '..', '..', 'templates', 'scripts', 'ci', 'ask-lib.sh');
  const script = '. "$1/lib.sh"; . "$1/bounded-lib.sh"; . "$2"; . "$1/ask-hook-lib.sh"; ask_fix "$(ask_of_issue "$3")"';
  const r = spawnSync('sh', ['-c', script, 'sh', hooks, askLib, issue], { encoding: 'utf8', windowsHide: true });
  return shellValue((r.stdout || '').replace(/\r/g, ''));
}

function stateLabel(ctx) {
  if (!ctx.cmd) return null;
  const asks = fs.existsSync(path.join(__dirname, '..', '..', 'templates', 'scripts', 'ci', 'ask-lib.sh'));
  const waiting = asks ? R.waitingOnOwnerIssue(ctx.cmd) : '';
  if (waiting && ruleOn('ask-recommends-one')) {
    const fix = askFix(waiting);
    if (fix) {
      return 'Blocked setting #' + waiting + ' to waiting on the owner, because ' + fix + '. Then set the state again. The project-drive skill\'s "How to write an ask" shows the shape, with a bad ask and its rewrite.';
    }
  } else if (waiting && askFix(waiting)) {
    ruleOffNote(ctx.name, 'ask-recommends-one', ctx.session);
  }
  let mode = '';
  try { mode = fs.readFileSync(path.join(ctx.root, '.claude', 'issue-state.txt'), 'utf8').split('\n')[0].replace(/[\r ]/g, ''); } catch (e) { /* label mode */ }
  if (mode === 'project') {
    const hit = R.projectFlagReason(ctx.cmd);
    if (!hit || !gate(ctx, 'issue-has-state')) return null;
    return 'Blocked `' + hit + '` because every issue goes on the project board at filing, where its state is set; add `--project "<board title>"` and set its Status, then run it again.';
  }
  const hit = R.stateLabelReason(ctx.cmd);
  if (!hit || !gate(ctx, 'issue-has-state')) return null;
  return 'Blocked `' + hit + '` because every issue needs a State label at filing; add `--label state:ready` (or state:in-progress, state:waiting-on-owner, state:waiting-on-service, state:parked, state:dated, state:after-launch) and run it again.';
}

function batchMerge(ctx) {
  if (!ctx.cmd) return null;
  if (ctx.root && fs.existsSync(path.join(ctx.root, 'scripts', 'ci', 'merge-queue.sh')) && R.directMergeReason(ctx.cmd)) {
    if (!gate(ctx, 'land-through-queue')) return null;
    return 'Blocked `gh pr merge` because this project merges through its queue, which checks the folder, waits for a quiet main and batches; run `sh scripts/ci/merge-queue.sh --drain` to merge everything that is green, or `sh scripts/ci/merge-queue.sh --serial PR` for one pull request.';
  }
  const hit = R.batchMergeReason(ctx.cmd);
  if (!hit || !gate(ctx, 'land-through-queue')) return null;
  return 'Blocked merging ' + hit + ' pull requests one at a time because merging must not take longer than the development did; run `merge-queue.sh --batch PR...` to merge them in one integration run, `--drain` to merge everything green, or `--serial` if these must land alone.';
}

function ghBudget(ctx) {
  if (!ctx.cmd) return null;
  const hit = R.ghGraphqlReason(ctx.cmd);
  if (!hit) return null;
  const rec = budgetRead(ctx.root || '.', ctx.onBound);
  if (!rec) return null;
  const floor = Number(process.env.GH_BUDGET_MIN || 500) || 0;
  if (!budgetLow(rec, floor)) return null;
  if (!gate(ctx, 'github-budget')) return null;
  return 'Blocked `' + hit + '` because the hour\'s GraphQL budget is nearly spent and the next call would fail for everyone: ' + budgetLine(rec, Math.floor(Date.now() / 1000), floor) + ' A one-off read is `gh api repos/{owner}/{repo}/issues/N`; `sh scripts/gh-budget.sh` prints the budget again.';
}

// pushDir(command): for a git push, the folder it runs in ('.' when not
// named); '' when the command does not push, or only deletes or tags.
function pushDir(command) {
  const unq = (s) => s.replace(/^["']|["']$/g, '');
  let dir = '';
  for (const line of splitCommands(command)) {
    const [w, n] = words(line);
    const first = w[1].replace(/.*[\/\\]/, '').replace(/\.exe$/, '');
    if (first === 'cd' && n >= 2) { dir = unq(w[2]); continue; }
    if (first !== 'git') continue;
    let d = dir, i = 2;
    while (i <= n && /^-/.test(w[i])) {
      if (w[i] === '-C' && i < n) { d = unq(w[i + 1]); i += 2; continue; }
      if (w[i] === '-c' && i < n) { i += 2; continue; }
      i++;
    }
    if (w[i] !== 'push') continue;
    let skip = false;
    for (let j = i + 1; j <= n; j++) if (/^(--delete|-d|--tags|--dry-run|-n|--mirror)$/.test(w[j]) || /^:/.test(w[j])) { skip = true; break; }
    if (skip) continue;
    return d === '' ? '.' : d;
  }
  return '';
}

const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch (e) { return false; } };
// An MSYS path (/c/work/app) as Windows writes it, so a cd in the command is found.
const native = (p) => (process.platform === 'win32' && /^\/[a-zA-Z]\//.test(p) ? p[1].toUpperCase() + ':' + p.slice(2) : p);

function git(args, cwd) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8', windowsHide: true });
  return r.status === 0 ? shellValue((r.stdout || '').replace(/\r/g, '')) : null;
}

function localChecks(ctx) {
  if (!ctx.cmd || !ctx.cmd.includes('push')) return null;
  const dir = pushDir(ctx.cmd);
  if (!dir) return null;
  let cwd = native(jsonField(ctx.input, 'cwd'));
  if (!cwd || !isDir(cwd)) cwd = process.cwd();
  const where = path.resolve(cwd, native(dir));
  if (!isDir(where)) return null;
  const top = git(['rev-parse', '--show-toplevel'], where);
  if (!top || !fs.existsSync(path.join(top, 'scripts', 'ci', 'checks-local.sh'))) return null;
  const branch = git(['symbolic-ref', '-q', '--short', 'HEAD'], where) || '';
  if (branch === '' || branch === 'main' || branch === 'master') return null;
  const r = spawnSync('sh', ['-c', 'sh scripts/ci/checks-local.sh 2>&1'], { cwd: top, encoding: 'utf8', windowsHide: true });
  if (r.status === 0) return null;
  if (!gate(ctx, 'quick-checks')) return null;
  const out = shellValue((r.stdout || '').replace(/\r/g, ''));
  if (r.status === 3) {
    return 'Blocked the push because its quick checks could not finish in time, so this change was not checked (nothing failed). Push again when the machine is quieter, or set CHECKS_LOCAL_SECONDS higher (sh scripts/ci/checks-local.sh runs them by hand):\n' + out;
  }
  return 'Blocked the push because the quick checks CI runs on a pull request fail here, and would fail there too. Fix what they say, commit, and push again (sh scripts/ci/checks-local.sh runs them by hand):\n' + out;
}

// name, the seconds the hook is allowed, the check: hooks.json's order.
const BASH = [
  ['block-rule-switch', 10, ruleSwitch],
  ['block-loose-ends', 10, looseEnds],
  ['block-delete', 10, blockDelete],
  ['block-force-push', 10, blockForcePush],
  ['block-full-test-sweep', 10, fullTestSweep],
  ['require-state-label', 10, stateLabel],
  ['require-batch-merge', 10, batchMerge],
  ['require-gh-budget', 10, ghBudget],
  ['require-local-checks', 90, localChecks],
];

module.exports = { BASH };
