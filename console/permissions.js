'use strict';
// node console/cli.js permissions
//
// The one setup step that is the person's: the agent is not allowed to
// grant itself permissions, so this writes .claude/settings.json's allow
// rules when a person runs it in a terminal, merging with any rules
// already there, then commits the file and opens the pull request.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const COMMAND = 'node console/cli.js permissions';
const WHY = `The agent is not allowed to grant itself permissions, so this is the one setup step that is yours. Run it yourself in a terminal: ${COMMAND}`;

// Each rule as a sentence, the commands it allows, and its default answer:
// deploy asks, the rest default to yes.
const RULES = [
  { id: 'deploy', sentence: 'Let the agent start a deploy', defaultYes: false, allow: [
    'Bash(gh workflow run deploy.yml:*)',
    'Bash(gh api -X POST repos/{owner}/{repo}/actions/workflows/deploy.yml/dispatches:*)'] },
  { id: 'queue', sentence: 'Let it run the merge queue', defaultYes: true, allow: ['Bash(sh scripts/ci/merge-queue.sh:*)'] },
  { id: 'prs', sentence: 'Let it open and check pull requests', defaultYes: true, allow: [
    'Bash(sh scripts/pr-open.sh:*)', 'Bash(sh scripts/pr-checks.sh:*)'] },
  { id: 'issues', sentence: 'Let it file issues and set their state', defaultYes: true, allow: [
    'Bash(sh scripts/issue-open.sh:*)', 'Bash(sh scripts/state.sh:*)'] },
  { id: 'tidy', sentence: 'Let it end worktrees, record decisions and take the next number', defaultYes: true, allow: [
    'Bash(sh scripts/worktrees.sh:*)', 'Bash(sh scripts/decisions.sh:*)', 'Bash(sh scripts/next-number.sh:*)'] },
  { id: 'pages', sentence: 'Let it build and check the status page and the design files', defaultYes: true, allow: [
    'Bash(sh scripts/ci/design-check.sh:*)', 'Bash(sh status/build.sh:*)', 'Bash(sh status/check.sh:*)',
    'Bash(node scripts/design/generate.mjs:*)'] },
];

// mergeSettings(existing, allow): the settings with every rule in allow
// added once to permissions.allow; every other key and rule is kept.
function mergeSettings(existing, allow) {
  const out = existing && typeof existing === 'object' ? JSON.parse(JSON.stringify(existing)) : {};
  if (!out.permissions || typeof out.permissions !== 'object') out.permissions = {};
  const list = Array.isArray(out.permissions.allow) ? out.permissions.allow : [];
  for (const r of allow) if (!list.includes(r)) list.push(r);
  out.permissions.allow = list;
  return out;
}

// answer(rule, typed): yes or no for what the person typed; Enter takes the default.
function answer(rule, typed) {
  const a = String(typed || '').trim().toLowerCase();
  return a === '' ? rule.defaultYes : a.startsWith('y');
}

// refusal(isTTY): the sentence to stop with when there is no terminal, else null.
function refusal(isTTY) {
  return isTTY ? null : WHY;
}

async function run(root, io = { stdin: process.stdin, stdout: process.stdout, stderr: process.stderr }) {
  const stop = refusal(Boolean(io.stdin.isTTY && io.stdout.isTTY));
  if (stop) { io.stderr.write(stop + '\n'); return 2; }
  const out = (s) => io.stdout.write(s + '\n');
  out('The agent is not allowed to grant itself permissions, so this is the one setup step that is yours.');
  out('Answer yes or no for each. Enter takes the answer in capitals.\n');
  const rl = require('readline').createInterface({ input: io.stdin, output: io.stdout });
  const chosen = [];
  for (const r of RULES) {
    out(`${r.sentence}\n  ${r.allow.join('\n  ')}`);
    const typed = await new Promise((resolve) => rl.question(r.defaultYes ? '  YES or no? ' : '  yes or NO? ', resolve));
    if (answer(r, typed)) chosen.push(...r.allow);
  }
  rl.close();
  if (!chosen.length) { out('Nothing chosen, so nothing was written.'); return 0; }
  const file = path.join(root, '.claude', 'settings.json');
  let existing = {};
  if (fs.existsSync(file)) {
    try { existing = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {
      io.stderr.write('.claude/settings.json could not be read, so it was left as it is.\n');
      return 1;
    }
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(mergeSettings(existing, chosen), null, 2) + '\n');
  out('Wrote .claude/settings.json.');
  const title = "Allow the agent the project's own commands";
  try {
    const git = (...a) => execFileSync('git', a, { cwd: root, stdio: 'inherit' });
    git('switch', '-c', 'allow-agent-commands');
    git('add', '.claude/settings.json');
    git('commit', '-m', title);
    git('push', '-u', 'origin', 'allow-agent-commands');
    const body = path.join(root, '.scratch', 'permissions-body.md');
    fs.mkdirSync(path.dirname(body), { recursive: true });
    fs.writeFileSync(body, 'Lets the agent run the commands chosen in the permissions step, so it no longer stops at them.\n');
    execFileSync('sh', ['scripts/pr-open.sh', title, body], { cwd: root, stdio: 'inherit' });
  } catch (e) {
    out('The file is written, but the pull request was not opened. Commit .claude/settings.json and open one yourself.');
    return 1;
  }
  out("Next: restart the agent's session so the rules load.");
  return 0;
}

module.exports = { COMMAND, RULES, WHY, answer, mergeSettings, refusal, run };
