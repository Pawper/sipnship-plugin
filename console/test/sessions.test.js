'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const sessions = require('../sessions');
const send = require('../brief-send');

const fx = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions', 'watering-session.jsonl');
const log = fs.readFileSync(fx, 'utf8');

test('a last line over twelve words is cut at twelve', () => {
  const long = 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen';
  const cut = sessions.lastLine(long);
  assert.strictEqual(cut.replace('…', '').split(' ').length, 12);
  assert.ok(cut.endsWith('twelve…'));
  assert.strictEqual(sessions.lastLine('Reading the schedule screen first.'), 'Reading the schedule screen first.');
  assert.strictEqual(sessions.lastLine(''), '');
});

test('a session is read from its log: issues, model, start, branch, last line, tokens', () => {
  const s = sessions.readSession(log, 'abc');
  assert.deepStrictEqual(s.issues, [12, 14]);
  assert.strictEqual(s.model, 'claude-sonnet-5-5');
  assert.strictEqual(s.started, '2026-10-30T22:04:11.000Z');
  assert.strictEqual(s.branch, 'watering-schedule');
  assert.deepStrictEqual(s.worktree, { name: 'watering', path: '/work/rooftop-garden/worktrees/watering' });
  assert.strictEqual(s.lastLine.replace('…', '').split(' ').length, 12);
  assert.strictEqual(s.tokens, 1500 + 6600);
  assert.strictEqual(s.spend, undefined, 'spend is left out when the runtime does not report it');
  assert.strictEqual(s.startedWith, undefined);
});

test('a log with nothing in it is no session', () => {
  assert.strictEqual(sessions.readSession('not json\n', 'x'), undefined);
});

test('recent sessions of the repository\'s worktrees are sampled, with how they started', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-sess-'));
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-root-'));
  const tree = '/work/rooftop-garden/worktrees/watering';
  const folder = path.join(home, sessions.logFolder(tree));
  fs.mkdirSync(folder, { recursive: true });
  fs.writeFileSync(path.join(folder, 'abc.jsonl'), log);
  fs.mkdirSync(path.join(root, '.scratch', 'drive'), { recursive: true });
  fs.writeFileSync(path.join(root, '.scratch', 'drive', 'started-with.tsv'), 'watering\tround\n');
  const got = sessions.readSessions({ root, logsDir: home, worktrees: [tree] });
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].session, 'abc');
  assert.strictEqual(got[0].startedWith, 'round');
  // An old log is gone from the sample.
  const none = sessions.readSessions({ root, logsDir: home, worktrees: [tree], now: Date.now() + 3 * 3600 * 1000 });
  assert.deepStrictEqual(none, []);
});

test('the brief carries the sessions, each last line cut, and none when there are none', () => {
  const long = { session: 's', started: '2026-10-30T22:04:11.000Z', lastLine: 'a b c d e f g h i j k l m n o' };
  const b = send.briefBody('Main: ok', { now: new Date('2026-10-31T01:00:00Z'), machine: 'desk', sessions: [long] });
  assert.strictEqual(b.sessions.length, 1);
  assert.strictEqual(b.sessions[0].lastLine.replace('…', '').split(' ').length, 12);
  assert.strictEqual(send.briefBody('Main: ok', { machine: 'desk', sessions: [] }).sessions, undefined);
});

test('a session that named no issue is matched by the issue in its branch', () => {
  const quiet = [
    JSON.stringify({ type: 'user', timestamp: '2026-10-30T22:04:11.000Z', gitBranch: 'issue-214-watering', cwd: '/work/rooftop-garden/worktrees/watering', message: { content: 'Water the beds on a schedule' } }),
    JSON.stringify({ type: 'assistant', timestamp: '2026-10-30T22:05:00.000Z', message: { model: 'claude-sonnet-5-5', content: [{ type: 'text', text: 'Reading the schedule screen.' }] } }),
  ].join('\n');
  assert.deepStrictEqual(sessions.readSession(quiet, 'abc').issues, [214]);
});

const fxDir = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions');
const read = (f, opts) => sessions.readSession(fs.readFileSync(path.join(fxDir, f), 'utf8'), 'x', opts);

test('a session carries tokens in, cached and out beside the total', () => {
  const s = read('watering-session.jsonl');
  assert.strictEqual(s.tokensIn + s.tokensCached + s.tokensOut, s.tokens);
  const c = read('compost-local-session.jsonl');
  assert.deepStrictEqual([c.tokensIn, c.tokensCached, c.tokensOut], [800 + 100 + 500, 8500, 350]);
  assert.strictEqual(c.tokensIn + c.tokensCached + c.tokensOut, c.tokens);
});

test('a model the machine declared is a local model: prefixed, with a spend of 0', () => {
  const s = read('compost-local-session.jsonl', { localModels: ['qwen3'] });
  assert.strictEqual(s.model, 'local/qwen3');
  assert.strictEqual(s.spend, 0);
  const plain = read('compost-local-session.jsonl');
  assert.strictEqual(plain.model, 'qwen3');
  assert.strictEqual(plain.spend, undefined);
});

test('an id already prefixed ollama/, lmstudio/ or local/ stays and costs nothing', () => {
  const s = read('compost-prefixed-session.jsonl');
  assert.strictEqual(s.model, 'ollama/qwen3:8b');
  assert.strictEqual(s.spend, 0);
  assert.strictEqual(sessions.modelId('lmstudio/qwen3'), 'lmstudio/qwen3');
  assert.strictEqual(sessions.modelId('claude-sonnet-5-5', ['qwen3']), 'claude-sonnet-5-5');
  assert.strictEqual(read('watering-session.jsonl').spend, undefined, 'a frontier model spend is not guessed');
});

test('the kind of work comes from the drive note, only when it is one of the known kinds', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-kind-'));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-kind-home-'));
  const tree = '/work/rooftop-garden/worktrees/watering';
  const folder = path.join(home, sessions.logFolder(tree));
  fs.mkdirSync(folder, { recursive: true });
  fs.writeFileSync(path.join(folder, 'abc.jsonl'), log);
  fs.mkdirSync(path.join(root, '.scratch', 'drive'), { recursive: true });
  const note = path.join(root, '.scratch', 'drive', 'started-with.tsv');
  fs.writeFileSync(note, 'watering\tround\tfixing-check\n');
  let got = sessions.readSessions({ root, logsDir: home, worktrees: [tree] });
  assert.strictEqual(got[0].category, 'fixing-check');
  assert.strictEqual(got[0].startedWith, 'round');
  fs.writeFileSync(note, 'watering\tround\tgardening\n');
  got = sessions.readSessions({ root, logsDir: home, worktrees: [tree] });
  assert.strictEqual(got[0].category, undefined);
  assert.ok(sessions.CATEGORIES.includes('releasing-plugin'));
});

test('an agent a session started is sampled from the subagents folder, with its own issue and branch', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-agent-'));
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-agent-root-'));
  const main = '/work/rooftop-garden';
  // The runtime files an agent's log under the session that started it, in that session's folder.
  const sub = path.join(home, sessions.logFolder(main), 'parent-session', 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  fs.copyFileSync(path.join(fxDir, 'subagent-session.jsonl'), path.join(sub, 'agent-a1b2c3d4e5f6a7b8c.jsonl'));
  fs.writeFileSync(path.join(sub, 'agent-a1b2c3d4e5f6a7b8c.meta.json'), JSON.stringify({ worktreeBranch: 'worktree-agent-a1b2c3d4e5f6a7b8c' }));
  const got = sessions.readSessions({ root, logsDir: home, worktrees: [main] });
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].session, 'agent-a1b2c3d4e5f6a7b8c');
  // Its issue is the one its pull request closes, not the other pull request it was told about.
  assert.deepStrictEqual(got[0].issues, [12]);
  assert.strictEqual(got[0].branch, 'worktree-agent-a1b2c3d4e5f6a7b8c', 'the branch it was given, not its parent session\'s');
  assert.strictEqual(got[0].worktree.name, 'agent-a1b2c3d4e5f6a7b8c');
  assert.strictEqual(got[0].lastLine, 'Reading the reminder screen first.');
});

test('a first message names its own issue before the others it mentions', () => {
  const first = (text) => sessions.readSession(JSON.stringify({ type: 'user', timestamp: '2026-11-02T18:00:00.000Z', message: { content: text } }), 'x').issues;
  assert.deepStrictEqual(first('Task: issue #31. Also read #8, the answer to it.'), [31]);
  assert.deepStrictEqual(first('Your issue: #31 (read it). Its sibling is #30.'), [31]);
  assert.deepStrictEqual(first('Work #8 and #31 together. Body: "Closes #31", "Refs #8".'), [31, 8]);
  assert.deepStrictEqual(first('Work issues #12 and #14 together.'), [12, 14]);
});
