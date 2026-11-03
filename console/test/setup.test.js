'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const tokens = require('../tokens');
const { setup, readSetup, setupLines } = require('../setup');

const scratch = path.resolve(__dirname, '..', '..', '..', '.scratch');
const home = () => { fs.mkdirSync(scratch, { recursive: true }); return fs.mkdtempSync(path.join(scratch, 'sns-setup-')); };
const sink = () => { const o = { text: '', write: (s) => { o.text += s; } }; return o; };
const T = 'sns_repo_' + 'Q'.repeat(43);

const reading = {
  items: [
    { id: 'runners', title: 'Your runners are online', state: 'needs-you', turn: { kind: 'needs-you', words: 'Needs you' }, say: "Maya's desktop is asking for your permission. Click Yes on its screen to add 3 runners.", fields: [{ label: 'Runners', value: '0' }], handles: [{ kind: 'link', label: 'Open the runners', href: 'https://github.com/maya/rooftop-garden/settings/actions/runners' }] },
    { id: 'plugin', title: 'The plugin is installed', state: 'done', say: 'The plugin is installed.', fields: [], handles: [] },
  ],
  done: 1,
  total: 2,
  complete: false,
  briefLine: 'Setup: 1 of 2 done. Your runners are online needs you.',
  dot: 'orange',
  advice: [{ say: 'Your queue can sign in as itself.', handle: { kind: 'copy', label: 'Copy the command', words: 'npx sipnship queue-identity' } }],
};

test('the lines are the Brief line, each item with its state, turn, sentence, fields and handle, then the advice', () => {
  const text = setupLines(reading).join('\n');
  assert.match(text, /^Setup: 1 of 2 done\./);
  assert.match(text, /Your runners are online \(Needs you, Needs you\)\n {2}Maya's desktop is asking for your permission\./);
  assert.match(text, / {2}Runners: 0\n {2}Open the runners: https:\/\/github\.com\//);
  assert.match(text, /The plugin is installed \(Done\)/);
  assert.match(text, /Advice\n {2}Your queue can sign in as itself\.\n {2}Copy the command: npx sipnship queue-identity$/);
  assert.match(setupLines({ ...reading, complete: true }).join('\n'), /^Setup is done\./);
});

test('setup reads the repository with the connected machine\'s token and prints the checklist', async () => {
  const env = { SIPNSHIP_HOME: home() };
  try {
    tokens.put({ repoId: 42, fullName: 'maya/rooftop-garden', token: T, machine: "Maya's desktop" }, env);
    const seen = [];
    const out = sink();
    const code = await setup({ repo: 'maya/rooftop-garden', env, out, fetchFn: async (u, i) => { seen.push([u, i.headers.authorization]); return Response.json(reading); } });
    assert.strictEqual(code, 0);
    assert.match(seen[0][0], /\/v1\/repos\/maya\/rooftop-garden\/setup$/);
    assert.strictEqual(seen[0][1], `Bearer ${T}`);
    assert.match(out.text, /Your runners are online/);
    assert.doesNotMatch(out.text, /sns_repo_/);
  } finally {
    fs.rmSync(env.SIPNSHIP_HOME, { recursive: true, force: true });
  }
});

test('the service\'s refusal is passed on as it said it, an unreachable service is said plainly, and no repository asks for one', async () => {
  const env = { SIPNSHIP_HOME: home() };
  try {
    const out = sink();
    assert.strictEqual(await setup({ repo: 'maya/rooftop-garden', env, out, fetchFn: async () => Response.json({ code: 'not_connected', say: 'Install SipNShip first.' }, { status: 404 }) }), 1);
    assert.match(out.text, /^Install SipNShip first\.\n$/);
    const down = await readSetup(async () => { throw new Error('offline'); }, 'https://sipnship.dev', 'maya/rooftop-garden');
    assert.strictEqual(down.ok, false);
    assert.match(down.text, /could not be reached/);
    const none = sink();
    assert.strictEqual(await setup({ repo: 'nope', env, out: none }), 2);
    assert.match(none.text, /Name the repository/);
  } finally {
    fs.rmSync(env.SIPNSHIP_HOME, { recursive: true, force: true });
  }
});
