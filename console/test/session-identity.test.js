'use strict';
// Which issue, worktree and name each sampled session carries: by its pull
// request body, by its branch, by its first message, and an agent under the
// session that started it. Fixtures are the rooftop-garden sample project.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const sessions = require('../sessions');
const { freshLog } = require('./fresh-log');

const fxDir = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions');
const tmp = (p) => fs.mkdtempSync(path.join(os.tmpdir(), p));

/** A log folder holding one log for the worktree, written as now so it counts as recent. */
function placeLog(home, tree, fixture, file, sub) {
  const folder = path.join(home, sessions.logFolder(tree), ...(sub ? [sub, 'subagents'] : []));
  fs.mkdirSync(folder, { recursive: true });
  freshLog(path.join(fxDir, fixture), path.join(folder, file));
  return folder;
}

test('the issue a branch names: issue-N, a leading number or a trailing one, never a runtime or batch branch', () => {
  assert.deepStrictEqual(sessions.issuesInBranch('issue-214-watering'), [214]);
  assert.deepStrictEqual(sessions.issuesInBranch('214-watering'), [214]);
  assert.deepStrictEqual(sessions.issuesInBranch('frost-alerts-208'), [208]);
  assert.deepStrictEqual(sessions.issuesInBranch('worktree-agent-a5e249ed9001e1a2c'), []);
  assert.deepStrictEqual(sessions.issuesInBranch('batch-2026-11-03-095215'), []);
  assert.deepStrictEqual(sessions.issuesInBranch('main'), []);
});

test('a session is found by the issue its pull request body closes, before its branch or its first message', () => {
  const home = tmp('sns-id-home-');
  const tree = tmp('sns-id-tree-');
  const folder = placeLog(home, tree, 'branch-number-session.jsonl', 'abc.jsonl');
  // The fixture's worktree is the sample project's; here it is the temporary one, where a body can be written.
  const log = path.join(folder, 'abc.jsonl');
  fs.writeFileSync(log, fs.readFileSync(log, 'utf8').split('/work/rooftop-garden/worktrees/frost-alerts-208').join(tree.replace(/\\/g, '/')));
  const got = sessions.readSessions({ root: tree, logsDir: home, worktrees: [tree] });
  assert.strictEqual(got.length, 1);
  // No body yet: the branch's number, not the issues its first message only mentioned.
  assert.deepStrictEqual(got[0].issues, [208]);
  fs.mkdirSync(path.join(tree, '.scratch'), { recursive: true });
  fs.writeFileSync(path.join(tree, '.scratch', 'body.md'), 'Frost alerts name their bed.\n\nCloses #211\nRefs #9\n');
  const again = sessions.readSessions({ root: tree, logsDir: home, worktrees: [tree] });
  assert.deepStrictEqual(again[0].issues, [211]);
});

test('an agent is a session of its own under the one that started it, with its worktree and task', () => {
  const home = tmp('sns-id-agent-');
  const main = '/work/rooftop-garden';
  const folder = placeLog(home, main, 'subagent-session.jsonl', 'agent-a1b2c3d4e5f6a7b8c.jsonl', '5d8e2c41-7a10-4b3e-9f62-0c1d2e3f4a5b');
  fs.writeFileSync(path.join(folder, 'agent-a1b2c3d4e5f6a7b8c.meta.json'), JSON.stringify({ worktreeBranch: 'worktree-agent-a1b2c3d4e5f6a7b8c', worktreePath: '/work/rooftop-garden/.claude/worktrees/agent-a1b2c3d4e5f6a7b8c', description: 'Watering reminder' }));
  const [s] = sessions.readSessions({ root: tmp('sns-id-root-'), logsDir: home, worktrees: [main] });
  assert.strictEqual(s.session, 'agent-a1b2c3d4e5f6a7b8c');
  assert.strictEqual(s.parent, '5d8e2c41-7a10-4b3e-9f62-0c1d2e3f4a5b');
  assert.strictEqual(s.title, 'Watering reminder');
  assert.strictEqual(s.runtime, 'Claude Code');
  assert.strictEqual(s.worktree.name, 'agent-a1b2c3d4e5f6a7b8c');
  // The runtime's branch names no issue, so its first message does.
  assert.deepStrictEqual(s.issues, [12]);
});

test('a titled session carries its title, and its worktree is where it started, not where it last looked', () => {
  const s = sessions.readSession(fs.readFileSync(path.join(fxDir, 'titled-session.jsonl'), 'utf8'), '5d8e2c41-7a10-4b3e-9f62-0c1d2e3f4a5b');
  assert.strictEqual(s.title, 'Rooftop rounds');
  assert.strictEqual(s.session, '5d8e2c41-7a10-4b3e-9f62-0c1d2e3f4a5b');
  assert.deepStrictEqual(s.worktree, { name: 'rooftop-garden', path: '/work/rooftop-garden' });
  assert.deepStrictEqual(s.issues, [12, 15]);
});
