'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const billing = require('../billing');
const sessions = require('../sessions');
const { freshLog } = require('./fresh-log');

const homeWith = (credentials) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-billing-'));
  if (credentials !== undefined) {
    fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(home, '.claude', '.credentials.json'), typeof credentials === 'string' ? credentials : JSON.stringify(credentials));
  }
  return home;
};

test('a subscription sign-in is a plan, named by its subscription type', () => {
  const home = homeWith({ claudeAiOauth: { accessToken: 'secret-not-sent', subscriptionType: 'max' } });
  assert.deepStrictEqual(billing.claudeSignIn({ env: {}, home }), { billing: 'plan', planName: 'Max' });
});

test('a plan whose type is not one plain word has no name, and nothing else is read', () => {
  const home = homeWith({ claudeAiOauth: { accessToken: 'secret-not-sent', subscriptionType: 'maya@example.com' } });
  assert.deepStrictEqual(billing.claudeSignIn({ env: {}, home }), { billing: 'plan' });
});

test('a key in the environment is a key, even beside a subscription sign-in, and is never carried', () => {
  const home = homeWith({ claudeAiOauth: { subscriptionType: 'pro' } });
  const got = billing.claudeSignIn({ env: { ANTHROPIC_API_KEY: 'sk-ant-secret' }, home });
  assert.deepStrictEqual(got, { billing: 'key' });
  assert.ok(!JSON.stringify(got).includes('secret'));
});

test('no readable config is not known, never a guess', () => {
  assert.deepStrictEqual(billing.claudeSignIn({ env: {}, home: homeWith() }), { billing: 'unknown' });
  assert.deepStrictEqual(billing.claudeSignIn({ env: {}, home: homeWith('not json') }), { billing: 'unknown' });
  assert.deepStrictEqual(billing.claudeSignIn({ env: {}, home: homeWith({ other: 1 }) }), { billing: 'unknown' });
});

test('the session report carries billing for a hosted model and not for a local one', () => {
  const tree = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-billing-tree-'));
  const logs = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-billing-logs-'));
  const folder = path.join(logs, sessions.logFolder(tree));
  fs.mkdirSync(folder, { recursive: true });
  const now = Date.now();
  freshLog(path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions', 'watering-session.jsonl'), path.join(folder, 'one.jsonl'), now);
  const [s] = sessions.readSessions({ root: tree, logsDir: logs, worktrees: [tree], now, signIn: { billing: 'plan', planName: 'Max' } });
  assert.strictEqual(s.billing, 'plan');
  assert.strictEqual(s.planName, 'Max');
  const [local] = sessions.readSessions({ root: tree, logsDir: logs, worktrees: [tree], now, localModels: [s.model], signIn: { billing: 'plan', planName: 'Max' } });
  assert.strictEqual(local.billing, undefined);
});
