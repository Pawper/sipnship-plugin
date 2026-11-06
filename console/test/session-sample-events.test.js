'use strict';
// The session sample reaches the service when a session dispatches an agent
// and when that agent stops, not only at the next session's start. The hook
// runs for each event against a fixture log folder (a session of Maya's
// rooftop-garden app and the agent it started) and a fake service, as the
// runtime runs it: one JSON object on its input.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const http = require('http');
const path = require('path');
const { execFileSync } = require('child_process');
const tokens = require('../tokens');
const sessions = require('../sessions');

const hook = path.join(__dirname, '..', '..', 'hooks', 'scripts', 'session-sample.sh');
const fxDir = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions');
const T = 'sns_repo_' + 'B'.repeat(43);
const PARENT = '5d8e2c41-7a10-4b3e-9f62-0c1d2e3f4a5b';
const AGENT = 'a1b2c3d4e5f6a7b8c';
const tmp = (p) => fs.mkdtempSync(path.join(os.tmpdir(), p));

function fake() {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => { seen.push(JSON.parse(body || '{}')); res.writeHead(204); res.end(); });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}

/** A project with its remote, a user folder holding its runtime logs, and a machine connected to it. */
function machine(url) {
  const project = tmp('sns-ev-proj-');
  execFileSync('git', ['init', '-q', project]);
  execFileSync('git', ['-C', project, 'remote', 'add', 'origin', 'https://github.com/acme/shop.git']);
  const tree = execFileSync('git', ['-C', project, 'worktree', 'list', '--porcelain'], { encoding: 'utf8' }).split(/\r?\n/)[0].slice(9).trim();
  const user = tmp('sns-ev-user-');
  const logs = path.join(user, '.claude', 'projects', sessions.logFolder(tree));
  fs.mkdirSync(logs, { recursive: true });
  fs.copyFileSync(path.join(fxDir, 'watering-session.jsonl'), path.join(logs, `${PARENT}.jsonl`));
  fs.utimesSync(path.join(logs, `${PARENT}.jsonl`), new Date(), new Date());
  const home = tmp('sns-ev-home-');
  tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, { SIPNSHIP_HOME: home });
  const env = { ...process.env, HOME: user, USERPROFILE: user, SIPNSHIP_HOME: home, SIPNSHIP_URL: url, CLAUDE_PROJECT_DIR: project, SIPNSHIP_SAMPLE_DELAY: '0', SIPNSHIP_SAMPLE_GAP: '0' };
  return { project, logs, home, env };
}

/** The runtime starting the agent: its log and meta file under the session that started it. */
function dispatch(m) {
  const sub = path.join(m.logs, PARENT, 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  fs.copyFileSync(path.join(fxDir, 'subagent-session.jsonl'), path.join(sub, `agent-${AGENT}.jsonl`));
  fs.utimesSync(path.join(sub, `agent-${AGENT}.jsonl`), new Date(), new Date());
  fs.writeFileSync(path.join(sub, `agent-${AGENT}.meta.json`), JSON.stringify({ description: 'Watering reminders skip rained beds' }));
}

function run(m, event, extra = {}) {
  const input = JSON.stringify({ session_id: PARENT, hook_event_name: event, cwd: m.project, ...extra });
  const started = Date.now();
  const out = execFileSync('sh', [hook], { input, env: m.env, encoding: 'utf8', timeout: 20000 });
  return { out, ms: Date.now() - started };
}

/** Waits, bounded, for the fake service to have heard n sends. */
async function heard(f, n, ms = 15000) {
  const until = Date.now() + ms;
  while (f.seen.length < n && Date.now() < until) await new Promise((r) => setTimeout(r, 100));
  return f.seen.length;
}

const agentIn = (body) => (body.sessions || []).find((s) => s.session === `agent-${AGENT}`);
const lineOf = (body, name = PARENT) => ((body.sessions || []).find((s) => s.session === name) || {}).lastLine;

/** A tool call as the runtime makes it: each PostToolUse hook whose matcher takes the tool runs the sample's script, with its arguments. */
function toolCall(m, tool, extra = {}) {
  const groups = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'hooks', 'hooks.json'), 'utf8')).hooks.PostToolUse || [];
  const input = JSON.stringify({ session_id: PARENT, hook_event_name: 'PostToolUse', cwd: m.project, tool_name: tool, tool_input: {}, ...extra });
  for (const g of groups) {
    if (!(g.matcher === '*' || new RegExp(`^(?:${g.matcher})$`).test(tool))) continue;
    for (const h of g.hooks) {
      const args = /session-sample\.sh"?((?:\s+\w+)*)\s*$/.exec(h.command);
      if (args) execFileSync('sh', [hook, ...args[1].trim().split(/\s+/).filter(Boolean)], { input, env: m.env, encoding: 'utf8', timeout: 20000 });
    }
  }
}

/** The agent says something new: one more assistant line in its log. */
function say(file, text) {
  fs.appendFileSync(file, JSON.stringify({ type: 'assistant', timestamp: new Date().toISOString(), message: { model: 'claude-sonnet-5-5', role: 'assistant', content: [{ type: 'text', text }] } }) + '\n');
}

/** The interval as gone by: the repository's mark set back past it. */
const sinceLast = (m, s) => fs.writeFileSync(path.join(m.home, 'brief-send', 'sample-at-acme-shop'), `${Math.floor(Date.now() / 1000) - s}\n`);
const quiet = () => new Promise((r) => setTimeout(r, 1500));

test('a dispatched agent reaches the service when it starts, and is said to have ended when it stops', async () => {
  const f = await fake();
  try {
    const m = machine(f.url);
    run(m, 'SessionStart');
    assert.strictEqual(await heard(f, 1), 1, 'the session start sends at once');
    assert.strictEqual(agentIn(f.seen[0]), undefined, 'no agent yet');

    dispatch(m);
    const start = run(m, 'SubagentStart', { agent_id: AGENT, agent_type: 'general-purpose' });
    assert.strictEqual(start.out, '', 'an agent starting prints nothing');
    assert.strictEqual(await heard(f, 2), 2, 'the agent starting sends, though the session start sent a moment ago');
    const started = agentIn(f.seen[1]);
    assert.ok(started, 'the agent is in the sample');
    assert.deepStrictEqual(started.issues, [12]);
    assert.strictEqual(started.parent, PARENT);
    assert.strictEqual(started.endedAt, undefined, 'a running agent has not ended');

    run(m, 'SubagentStop', { agent_id: AGENT, agent_type: 'general-purpose' });
    assert.strictEqual(await heard(f, 3), 3, 'the agent stopping sends, though its start sent a moment ago');
    const stopped = agentIn(f.seen[2]);
    assert.ok(stopped && stopped.endedAt, 'the stopped agent carries when it ended');
  } finally { f.server.close(); }
});

test('during a long turn of tool calls a changed line is sent, at most once in twenty seconds, and an unchanged one never', async () => {
  const f = await fake();
  try {
    const m = machine(f.url);
    // The real twenty seconds, set back by hand; a short spacing so the turn's end is not waited for.
    m.env.SIPNSHIP_SAMPLE_GAP = '1';
    const log = path.join(m.logs, `${PARENT}.jsonl`);
    run(m, 'SessionStart');
    assert.strictEqual(await heard(f, 1), 1, 'the session start sends at once');

    say(log, 'Reading the rain gauge readings for the last week.');
    toolCall(m, 'Bash');
    await quiet();
    assert.strictEqual(f.seen.length, 1, 'a tool call within twenty seconds of a send sends nothing');

    sinceLast(m, 21);
    toolCall(m, 'Read');
    assert.strictEqual(await heard(f, 2), 2, 'twenty seconds on, the changed line is sent after a tool call');
    assert.strictEqual(lineOf(f.seen[1]), 'Reading the rain gauge readings for the last week.');

    sinceLast(m, 21);
    toolCall(m, 'Grep');
    await quiet();
    assert.strictEqual(f.seen.length, 2, 'nothing changed since that send: nothing is sent');

    say(log, 'Skipping reminders for beds that got rain since the morning.');
    toolCall(m, 'Edit');
    await quiet();
    assert.strictEqual(f.seen.length, 2, 'the check just made counts against the twenty seconds');

    dispatch(m);
    sinceLast(m, 21);
    toolCall(m, 'Bash', { agent_id: AGENT });
    assert.strictEqual(await heard(f, 3), 3, 'a tool call in an agent sends the same way');
    assert.strictEqual(lineOf(f.seen[2]), 'Skipping reminders for beds that got rain since the morning.');
    assert.ok(agentIn(f.seen[2]), 'the agent its session started is in it');

    say(path.join(m.logs, PARENT, 'subagents', `agent-${AGENT}.jsonl`), 'Rain check written; running the reminder tests now.');
    sinceLast(m, 21);
    toolCall(m, 'Bash', { agent_id: AGENT });
    assert.strictEqual(await heard(f, 4), 4, "an agent's own line changing is sent");
    assert.strictEqual(agentIn(f.seen[3]).lastLine, 'Rain check written; running the reminder tests now.');

    say(log, 'Done: reminders skip the beds that rain watered.');
    run(m, 'Stop');
    assert.strictEqual(await heard(f, 5), 5, 'a turn ending close behind a send still sends its changed line');
    assert.strictEqual(lineOf(f.seen[4]), 'Done: reminders skip the beds that rain watered.');
    assert.ok(!f.seen.some((b) => JSON.stringify(b).includes(T)), 'no token rides in a body');
  } finally { f.server.close(); }
});

test('after a tool call within the twenty seconds, the hook starts no program and returns at once', () => {
  const m = machine('http://127.0.0.1:9');
  delete m.env.SIPNSHIP_SAMPLE_GAP;
  run(m, 'SessionStart');
  // Each program the hook could start is shadowed by one that leaves a mark; none may run.
  const bin = tmp('sns-ev-bin-');
  const ran = path.join(bin, 'ran');
  for (const p of ['git', 'node', 'date', 'cat', 'tr', 'awk', 'sed', 'mkdir', 'timeout', 'sleep']) {
    fs.writeFileSync(path.join(bin, p), `#!/bin/sh\necho ${p} >> "${ran.replace(/\\/g, '/')}"\nexit 1\n`, { mode: 0o755 });
  }
  const env = { ...m.env, PATH: `${bin}${path.delimiter}${process.env.PATH}` };
  const times = [];
  for (let i = 0; i < 5; i++) {
    const started = process.hrtime.bigint();
    const out = execFileSync('sh', [hook, 'tool'], { input: '{"hook_event_name":"PostToolUse","tool_name":"Bash"}', env, encoding: 'utf8' });
    times.push(Number(process.hrtime.bigint() - started) / 1e6);
    assert.strictEqual(out, '');
  }
  assert.strictEqual(fs.existsSync(ran) ? fs.readFileSync(ran, 'utf8') : '', '', 'no program ran');
  console.log(`# the no-send path took ${times.map((t) => t.toFixed(0)).join(', ')} ms, the shell's own start included`);
});

test('the dispatching tool call sends too, and a turn ending close behind a send with nothing changed sends nothing', async () => {
  const f = await fake();
  try {
    const m = machine(f.url);
    dispatch(m);
    run(m, 'PostToolUse', { tool_name: 'Agent', tool_input: { prompt: 'Your issue: #12' } });
    assert.strictEqual(await heard(f, 1), 1, 'the dispatch sends');
    assert.ok(agentIn(f.seen[0]));
    run(m, 'Stop');
    await new Promise((r) => setTimeout(r, 1500));
    assert.strictEqual(f.seen.length, 1, 'a turn ending within the minute of a send, its lines unchanged, sends nothing');
  } finally { f.server.close(); }
});

test('a send never holds the event up: the hook returns before the send is made', () => {
  // The service is unreachable and every send would wait out its bound; the hook does not.
  const m = machine('http://127.0.0.1:9');
  dispatch(m);
  m.env.SIPNSHIP_SAMPLE_DELAY = '3';
  const { out, ms } = run(m, 'SubagentStart', { agent_id: AGENT });
  assert.strictEqual(out, '');
  assert.ok(ms < 2500, `the hook returned in ${ms} ms`);
});

test('with the real spacing, sends for one repository stay six seconds apart and events close together share one', () => {
  const m = machine('http://127.0.0.1:9');
  delete m.env.SIPNSHIP_SAMPLE_DELAY;
  delete m.env.SIPNSHIP_SAMPLE_GAP;
  const mark = path.join(m.home, 'brief-send', 'sample-at-acme-shop');
  const now = Math.floor(Date.now() / 1000);
  run(m, 'SubagentStart', { agent_id: AGENT });
  const first = Number(fs.readFileSync(mark, 'utf8'));
  assert.ok(first >= now + 3 && first <= now + 5, 'an agent starting is read three seconds on, once its log is written');
  run(m, 'PostToolUse', { tool_name: 'Agent' });
  assert.strictEqual(Number(fs.readFileSync(mark, 'utf8')), first, 'the dispatching call is covered by the send already set');
  run(m, 'SubagentStop', { agent_id: AGENT });
  assert.strictEqual(Number(fs.readFileSync(mark, 'utf8')), first, 'so is a stop before that send reads');
  fs.writeFileSync(mark, `${now - 1}\n`);
  run(m, 'SubagentStop', { agent_id: AGENT });
  assert.ok(Number(fs.readFileSync(mark, 'utf8')) >= now + 5, 'a stop just after a send waits until six seconds after it, never dropped as too close');
  assert.ok(!fs.existsSync(path.join(m.home, 'brief-send', 'sample-at')), 'no machine-wide mark: each repository has its own');
});

test('an agent resumed after its stop is working again: its log moved on past the stop', () => {
  const tree = tmp('sns-ev-tree-');
  const logs = tmp('sns-ev-logs-');
  const sub = path.join(logs, sessions.logFolder(tree), PARENT, 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  const log = path.join(sub, `agent-${AGENT}.jsonl`);
  fs.copyFileSync(path.join(fxDir, 'subagent-session.jsonl'), log);
  const endedFile = path.join(logs, 'agents-ended.tsv');
  const stop = Math.floor(Date.now() / 1000) - 60;
  fs.writeFileSync(endedFile, `other\t${stop}\n${AGENT}\t${stop}\n`);
  const read = () => sessions.readSessions({ root: tree, logsDir: logs, worktrees: [tree], endedFile })[0];
  fs.utimesSync(log, new Date((stop - 5) * 1000), new Date((stop - 5) * 1000));
  assert.strictEqual(read().endedAt, new Date(stop * 1000).toISOString(), 'stopped, log untouched since');
  fs.utimesSync(log, new Date(), new Date());
  assert.strictEqual(read().endedAt, undefined, 'resumed: written a minute after its stop');
});
