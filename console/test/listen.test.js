'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const http = require('http');
const path = require('path');
const tokens = require('../tokens');
const rules = require('../request-rules');
const requestLog = require('../request-log');
const listen = require('../listen');
const { perform, PLUGIN_SCRIPT } = require('../listen-kinds');
const { ask } = require('../ask');
const { briefBody } = require('../brief-send');

const scratch = path.resolve(__dirname, '..', '..', '..', '.scratch');
const home = () => { fs.mkdirSync(scratch, { recursive: true }); return fs.mkdtempSync(path.join(scratch, 'sns-listen-')); };
const sink = () => { const o = { text: '', write: (s) => { o.text += s; } }; return o; };
const TOKEN = 'sns_repo_' + 'a'.repeat(43);
const NOW = Date.parse('2026-11-02T22:15:00Z');
const GOOD = { id: 'r-1', kind: 'deploy', param: '', askedBy: 'maya', approvedBy: 'maya', approvedAt: '2026-11-02T22:10:00Z' };
const CAN = rules.canKinds({ windows: true, ghAs: 'maya', admin: true, antivirus: true });

test('it is off until the person turns it on here, and the brief says nothing of it', async () => {
  const env = { SIPNSHIP_HOME: home() };
  assert.strictEqual(listen.readState(env).on, false);
  assert.strictEqual(listen.briefCan(env), undefined);
  const out = sink();
  assert.strictEqual(await listen.listen({ env, out, once: true }), 1);
  assert.match(out.text, /The listener is off\. Turn it on here, on this machine: npx sipnship listen on/);
  assert.strictEqual('can' in briefBody('Main: green', { now: new Date(NOW) }), false);
});

test('turning it on needs a connected repository, remembers its folder, and off stops it', () => {
  const env = { SIPNSHIP_HOME: home() };
  const out = sink();
  assert.strictEqual(listen.turn(true, { env, out, cwd: scratch, repo: 'maya/rooftop-garden', register: () => false }), 2);
  tokens.put({ repoId: 4242, fullName: 'maya/rooftop-garden', token: TOKEN, machine: 'maya-desktop' }, env);
  assert.strictEqual(listen.turn(true, { env, out, cwd: scratch, repo: 'maya/rooftop-garden', register: () => true }), 0);
  assert.strictEqual(listen.readState(env).on, true);
  assert.strictEqual(listen.readState(env).roots['4242'], scratch);
  assert.strictEqual(listen.turn(false, { env, out, register: () => true }), 0);
  assert.strictEqual(listen.readState(env).on, false);
});

test('the brief carries what the listener can do only while it is on and seen alive', () => {
  const env = { SIPNSHIP_HOME: home() };
  listen.writeState({ on: true, roots: {}, can: ['deploy'], aliveAt: new Date(NOW).toISOString() }, env);
  assert.deepStrictEqual(listen.briefCan(env, NOW + 60000), ['deploy']);
  assert.strictEqual(listen.briefCan(env, NOW + 7 * 60000), undefined);
  assert.deepStrictEqual(briefBody('Main: green', { now: new Date(NOW), can: ['deploy'] }).can, ['deploy']);
});

test('it refuses an unknown kind, a bad parameter, an old request, a mismatched approver and a mismatched sign-in', () => {
  const r = (over) => rules.refusal({ ...GOOD, ...over }, { ghAs: 'maya', can: CAN, now: NOW });
  assert.strictEqual(r({}), null);
  assert.strictEqual(r({ kind: 'format-disk' }), 'refused');
  assert.strictEqual(r({ kind: 'add-runner', param: 'garden-4; rm -rf /' }), 'refused');
  assert.strictEqual(r({ kind: 'grant-permissions', param: 'queue,everything' }), 'refused');
  assert.strictEqual(r({ approvedAt: '2026-11-02T21:45:00Z' }), 'refused');
  assert.strictEqual(r({ approvedAt: '' }), 'refused');
  assert.strictEqual(r({ approvedBy: '' }), 'refused');
  assert.strictEqual(r({ approvedBy: 'sam' }), 'refused-person');
  assert.strictEqual(rules.refusal(GOOD, { ghAs: 'sam', can: CAN, now: NOW }), 'refused-person');
  assert.strictEqual(rules.refusal(GOOD, { ghAs: undefined, can: CAN, now: NOW }), 'refused-person');
  assert.strictEqual(rules.refusal({ ...GOOD, kind: 'scan-skip' }, { ghAs: 'maya', can: rules.canKinds({ windows: false, ghAs: 'maya' }), now: NOW }), 'refused');
  assert.strictEqual(r({ id: 'x; rm' }), 'refused');
});

test('what a machine can do follows what it found', () => {
  assert.deepStrictEqual(rules.canKinds({ windows: true, admin: true, antivirus: true }), []);
  assert.deepStrictEqual(rules.canKinds({ windows: false, ghAs: 'maya', admin: true }), ['grant-permissions', 'run-migration', 'deploy']);
  assert.deepStrictEqual(rules.canKinds({ windows: true, ghAs: 'maya', admin: true, antivirus: true }), rules.KINDS);
});

test('the step facts keep only the kind\'s own, so no log or command text rides along', () => {
  assert.deepStrictEqual(rules.stepFacts('add-runner', { runner: 'garden-4', log: 'token=abc', env: 'X=1' }), { runner: 'garden-4' });
  assert.deepStrictEqual(rules.stepFacts('deploy', { run: 123, say: 'text' }), { run: '123' });
  assert.deepStrictEqual(rules.stepFacts('scan-skip', { folders: 'runners,git,C:\\Users' }), { folders: 'runners,git' });
  assert.deepStrictEqual(rules.stepFacts('add-runner', { runner: 'garden-4; rm' }), {});
});

// A context that records every command and prompt, and runs none of them.
function recorder(over = {}) {
  const calls = [];
  const steps = [];
  const ctx = {
    root: scratch, fullName: 'maya/rooftop-garden', home: home(), now: (() => { let t = NOW; return () => (t += 1000); })(), sleep: async () => {},
    exec: (cmd, args) => { calls.push([cmd, ...args]); return { status: 0, stdout: over.stdout?.(cmd, args) ?? 'true\n' }; },
    elevated: async (file, args) => { calls.push(['elevated', file, ...args]); return over.code ?? 0; },
    step: async (s) => { steps.push(s); },
  };
  return { ctx, calls, steps };
}

test('add a runner runs its one script, elevated, then waits for GitHub to list it online', async () => {
  const { ctx, calls, steps } = recorder({ stdout: (cmd, args) => (args.includes('--jq') && String(args[1]).includes('/actions/runners') ? 'online\n' : 'true\n') });
  const r = await perform('add-runner', 'garden-4', ctx);
  assert.deepStrictEqual(r, { outcome: 'done', facts: { runner: 'garden-4' } });
  assert.deepStrictEqual(steps, ['asking', 'running']);
  assert.deepStrictEqual(calls.find((c) => c[0] === 'elevated'), ['elevated', path.join(scratch, 'scripts', 'ci', 'add-runner.ps1'), '-Name', 'garden-4']);
});

test('a runner that never shows online in five minutes is said so, and a missing admin right stops before Windows is asked', async () => {
  const a = recorder({ stdout: (cmd, args) => (String(args[1]).includes('/actions/runners') ? 'offline\n' : 'true\n') });
  assert.strictEqual((await perform('add-runner', 'garden-4', a.ctx)).outcome, 'not-online');
  const b = recorder({ stdout: () => 'false\n' });
  assert.strictEqual((await perform('add-runner', 'garden-4', b.ctx)).outcome, 'no-admin');
  assert.strictEqual(b.calls.some((c) => c[0] === 'elevated'), false);
});

test('Windows saying no or nobody answering are their own outcomes, and nothing else runs', async () => {
  const no = recorder({ code: 87 });
  assert.strictEqual((await perform('scan-skip', '', no.ctx)).outcome, 'declined-windows');
  assert.deepStrictEqual(no.steps, ['asking']);
  const none = recorder({ code: 'timeout' });
  assert.strictEqual((await perform('remove-runner', 'garden-4', none.ctx)).outcome, 'no-answer');
});

test('the antivirus kinds run the plugin\'s one script with the fixed folders, and say which were set', async () => {
  const skip = recorder();
  assert.deepStrictEqual(await perform('scan-skip', '', skip.ctx), { outcome: 'done', facts: { folders: 'runners,git,node,packages' } });
  assert.deepStrictEqual(skip.calls[0], ['elevated', PLUGIN_SCRIPT, '-Action', 'Add', '-Root', 'C:\\actions-runner-rooftop-garden']);
  const again = recorder();
  await perform('scan-again', '', again.ctx);
  assert.deepStrictEqual(again.calls[0].slice(2, 4), ['-Action', 'Remove']);
  assert.ok(fs.readFileSync(PLUGIN_SCRIPT, 'utf8').includes('Add-MpPreference'));
});

test('deploy and migration only dispatch their own workflow and finish when its run ends', async () => {
  const run = JSON.stringify([{ databaseId: 987654, status: 'completed', conclusion: 'success', createdAt: '2026-11-02T22:16:00Z' }]);
  const d = recorder({ stdout: (cmd, args) => (args[0] === 'run' ? run : '') });
  d.ctx.now = (() => { let t = Date.parse('2026-11-02T22:15:30Z'); return () => (t += 1000); })();
  assert.deepStrictEqual(await perform('deploy', '', d.ctx), { outcome: 'done', facts: { run: '987654' } });
  assert.deepStrictEqual(d.calls[0], ['gh', 'workflow', 'run', 'deploy.yml', '--ref', 'main']);
  const m = recorder({ stdout: (cmd, args) => (args[0] === 'api' ? 'watering-reminders\n' : run) });
  m.ctx.now = d.ctx.now;
  await perform('run-migration', '665', m.ctx);
  assert.deepStrictEqual(m.calls[1], ['gh', 'workflow', 'run', 'migrate.yml', '--ref', 'watering-reminders']);
  const failed = recorder({ stdout: (cmd, args) => (args[0] === 'run' ? run.replace('success', 'failure') : '') });
  failed.ctx.now = d.ctx.now;
  assert.strictEqual((await perform('deploy', '', failed.ctx)).outcome, 'failed');
});

test('an unknown kind runs nothing', async () => {
  const { ctx, calls } = recorder();
  assert.strictEqual((await perform('format-disk', '', ctx)).outcome, 'refused');
  assert.deepStrictEqual(calls, []);
});

// A fake service: it hands out lines and records each step and outcome posted back.
function service(lines) {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      if (req.method === 'GET') { seen.push({ get: req.url, auth: req.headers.authorization }); res.writeHead(200, { 'content-type': 'text/plain' }); res.end(lines); return; }
      seen.push({ post: req.url, body: JSON.parse(body) });
      res.writeHead(204); res.end();
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}

test('one poll checks each request again, runs what passes one at a time, reports each step, and logs one line each', async () => {
  const lines = ['r-1\tdeploy\t\tmaya\tmaya\t2026-11-02T22:10:00Z', 'r-2\tformat-disk\t\tmaya\tmaya\t2026-11-02T22:10:00Z', 'r-3\tdeploy\t\tmaya\tsam\t2026-11-02T22:10:00Z'].join('\n') + '\n';
  const s = await service(lines);
  const env = { SIPNSHIP_HOME: home(), SIPNSHIP_URL: s.url };
  const ran = [];
  const io = {
    env, say: () => {}, now: () => NOW,
    facts: () => ({ windows: true, ghAs: 'maya', admin: true, antivirus: true }),
    ctxFor: (entry, step) => ({ step, fullName: entry.fullName }),
  };
  const kinds = require('../listen-kinds');
  const original = kinds.KIND_RUNNERS.deploy;
  kinds.KIND_RUNNERS.deploy = async (ctx) => { await ctx.step('running'); ran.push('deploy'); return { outcome: 'done', facts: { run: '55', log: 'secret text' } }; };
  try {
    const r = await listen.serveRepo({ repoId: 4242, fullName: 'maya/rooftop-garden', token: TOKEN }, io);
    assert.strictEqual(r.reached, true);
  } finally { kinds.KIND_RUNNERS.deploy = original; s.server.close(); }
  assert.deepStrictEqual(ran, ['deploy']);
  assert.deepStrictEqual(s.seen[0], { get: '/v1/repos/4242/machine/requests/open', auth: `Bearer ${TOKEN}` });
  const posts = s.seen.filter((x) => x.post).map((x) => [x.post.split('/').slice(-2)[0], JSON.stringify(x.body)]);
  assert.deepStrictEqual(posts, [
    ['r-1', '{"step":"picked-up"}'],
    ['r-1', '{"step":"running"}'],
    ['r-1', '{"outcome":"done","facts":{"run":"55"}}'],
    ['r-2', '{"outcome":"refused","facts":{}}'],
    ['r-3', '{"outcome":"refused-person","facts":{}}'],
  ]);
  assert.ok(!JSON.stringify(s.seen).includes('secret text'));
  const log = requestLog.recent(20, env);
  assert.strictEqual(log.length, 3);
  assert.deepStrictEqual(log.map((l) => l.outcome).reverse(), ['done', 'refused', 'refused-person']);
});

test('the local log is one tab line per request, never any text from a command, and the last 20 are shown', () => {
  const env = { SIPNSHIP_HOME: home() };
  for (let i = 0; i < 25; i++) requestLog.append({ at: `2026-11-02T22:${String(i).padStart(2, '0')}:00Z`, kind: 'deploy', askedBy: 'maya', approvedBy: 'maya', outcome: 'done' }, env);
  assert.strictEqual(fs.readFileSync(requestLog.file(env), 'utf8').trim().split('\n').length, 25);
  assert.strictEqual(requestLog.recent(20, env).length, 20);
  const out = sink();
  listen.status({ env, out });
  assert.match(out.text, /What this machine did for you:/);
});

test('a read that cannot reach SipNShip runs nothing and says it was not reached', async () => {
  const r = await listen.serveRepo({ repoId: 4242, fullName: 'maya/rooftop-garden', token: TOKEN }, { env: { SIPNSHIP_URL: 'http://127.0.0.1:1' }, say: () => {}, facts: () => ({}), ctxFor: () => ({}) });
  assert.strictEqual(r.reached, false);
});

test('ask makes a proposal in the person\'s name and never offers permissions', async () => {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => { seen.push({ url: req.url, auth: req.headers.authorization, body: JSON.parse(body) }); res.writeHead(201, { 'content-type': 'application/json' }); res.end(JSON.stringify({ say: "sam asked to add a runner to maya-desktop." })); });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const env = { SIPNSHIP_HOME: home(), SIPNSHIP_URL: `http://127.0.0.1:${server.address().port}` };
  tokens.put({ repoId: 4242, fullName: 'maya/rooftop-garden', token: TOKEN, machine: 'maya-desktop' }, env);
  const run = () => 'gho_person\n';
  const out = sink();
  assert.strictEqual(await ask({ what: 'add-runner', param: 'garden-4', reason: 'builds wait', repo: 'maya/rooftop-garden', env, out, run }), 0);
  assert.deepStrictEqual(seen[0], { url: '/v1/repos/maya/rooftop-garden/machines/maya-desktop/requests', auth: 'Bearer gho_person', body: { kind: 'add-runner', param: 'garden-4', reason: 'builds wait', via: 'cli' } });
  assert.match(out.text, /waits for approval on the dashboard/);
  assert.strictEqual(await ask({ what: 'migrate', repo: 'maya/rooftop-garden', env, out: sink(), run }), 0);
  assert.strictEqual(seen[1].body.kind, 'run-migration');
  assert.strictEqual(seen[1].body.param, 'main');
  const refused = sink();
  assert.strictEqual(await ask({ what: 'grant-permissions', repo: 'maya/rooftop-garden', env, out: refused, run }), 2);
  assert.match(refused.text, /yours alone/);
  assert.strictEqual(await ask({ what: 'remove-runner', param: 'garden 4; rm', repo: 'maya/rooftop-garden', env, out: sink(), run }), 2);
  server.close();
});

test('granting permissions writes the chosen rules in a fresh worktree from main and opens a pull request, never pushing main', async () => {
  const { ctx, calls } = recorder({ stdout: (cmd) => (cmd === 'sh' ? 'https://github.com/maya/rooftop-garden/pull/671\n' : '') });
  const r = await perform('grant-permissions', 'queue,prs', ctx);
  assert.deepStrictEqual(r, { outcome: 'opened', facts: { pr: '671' } });
  assert.ok(calls.some((c) => c[0] === 'git' && c[1] === 'fetch' && c[2] === 'origin'));
  assert.ok(calls.some((c) => c[1] === 'worktree' && c.includes('origin/main')));
  assert.ok(calls.every((c) => !(c[0] === 'git' && c[1] === 'push' && c.includes('main'))));
  const branch = calls.find((c) => c[1] === 'worktree')[4];
  const settings = JSON.parse(fs.readFileSync(path.join(ctx.home, 'worktrees', branch, '.claude', 'settings.json'), 'utf8'));
  assert.ok(settings.permissions.allow.includes('Bash(sh scripts/ci/merge-queue.sh:*)'));
  assert.ok(settings.permissions.allow.includes('Bash(sh scripts/pr-open.sh:*)'));
  assert.ok(!settings.permissions.allow.some((a) => a.includes('deploy.yml')));
});

test('the question at the end of connect defaults to No', async () => {
  const env = { SIPNSHIP_HOME: home() };
  const out = sink();
  assert.strictEqual(await listen.offerOn({ env, out, ask: async () => '' }), false);
  assert.strictEqual(await listen.offerOn({ env, out, ask: async () => 'no' }), false);
  assert.strictEqual(listen.readState(env).on, false);
  assert.strictEqual(await listen.offerOn({ env, out, input: { isTTY: false }, cwd: scratch }), false);
});
