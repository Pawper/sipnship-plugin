'use strict';
// Tests for the app's one-line refusal record, the template the plugin ships
// (templates/live/live-problem.ts). Written as Maya's rooftop-garden app: her
// plant-photo service refused by Google. The template is TypeScript with only
// erasable types, so Node loads it as it is.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const fs = require('node:fs');

const file = path.join(__dirname, '..', '..', 'templates', 'live', 'live-problem.ts');
const skip = process.features.typescript ? false : 'needs a Node that runs TypeScript (22.18 or later)';
const t = (name, fn) => test(name, { skip }, fn);
const load = () => import(pathToFileURL(file).href);

const KEY = 'AIzaSyHIDDEN-KEY-0123456789';
const googleRefusal = (status, reason, project) =>
  new Response(JSON.stringify({
    error: {
      code: status,
      message: `Cloud Vision has not been used in project ${project} (key=${KEY}) before. Prompt was: describe my tomatoes`,
      status: 'PERMISSION_DENIED',
      details: [{ '@type': 'type.googleapis.com/google.rpc.ErrorInfo', reason, metadata: { consumer: `projects/${project}` } }],
    },
  }), { status });

t('a Google refusal gives the reason and the project number', async () => {
  const h = await load();
  h.forgetFolds();
  const lines = [];
  const details = await h.refusalOf(googleRefusal(403, 'SERVICE_DISABLED', '492817306255'));
  h.record('vision', 'plant-photos', details, (l) => lines.push(l), 1000);
  assert.deepEqual(lines, ['sipnship live/1 service=vision feature=plant-photos status=403 reason=SERVICE_DISABLED account=492817306255 count=1']);
});

t('the provider message, a prompt and a key never reach the line', async () => {
  const h = await load();
  h.forgetFolds();
  const lines = [];
  const res = googleRefusal(403, 'API_KEY_INVALID', '492817306255');
  const details = await h.refusalOf(res);
  h.record('vision', 'plant-photos', details, (l) => lines.push(l), 1000);
  const all = lines.join('\n');
  assert.ok(!all.includes(KEY));
  assert.ok(!all.includes('tomatoes'));
  assert.ok(!all.includes('has not been used'));
});

t('the helper reads the response from a copy, so the app can still read it', async () => {
  const h = await load();
  const res = googleRefusal(403, 'SERVICE_DISABLED', '1');
  await h.refusalOf(res);
  assert.equal(res.bodyUsed, false);
});

t('Stripe, an OpenAI-style type and a plain sign-in error each give their reason', async () => {
  const h = await load();
  assert.equal(h.detailsOfBody({ error: { code: 'api_key_expired', message: 'x' } }).reason, 'api_key_expired');
  assert.equal(h.detailsOfBody({ error: { type: 'insufficient_quota', message: 'x' } }).reason, 'insufficient_quota');
  assert.equal(h.detailsOfBody({ error: 'invalid_grant', error_description: 'Bad things' }).reason, 'invalid_grant');
  assert.equal(h.detailsOfBody({ error: { code: 'has spaces and $ymbols' } }).reason, undefined);
  assert.equal(h.detailsOfBody('not an object').reason, undefined);
});

t('a flood of failures in a minute is one line carrying its count', async () => {
  const h = await load();
  h.forgetFolds();
  const lines = [];
  const d = { status: '403', reason: 'SERVICE_DISABLED', account: '492817306255' };
  for (let i = 0; i < 5; i++) h.record('vision', 'plant-photos', d, (l) => lines.push(l), 1000 + i * 1000);
  assert.equal(lines.length, 1);
  h.record('vision', 'plant-photos', d, (l) => lines.push(l), 1000 + 61000);
  assert.equal(lines.length, 2);
  assert.match(lines[1], / count=5$/);
});

t('a different cause is its own line', async () => {
  const h = await load();
  h.forgetFolds();
  const lines = [];
  h.record('vision', 'plant-photos', { status: '403', reason: 'SERVICE_DISABLED' }, (l) => lines.push(l), 1000);
  h.record('vision', 'plant-photos', { status: '429' }, (l) => lines.push(l), 1001);
  h.record('vision', 'seed-orders', { status: '403', reason: 'SERVICE_DISABLED' }, (l) => lines.push(l), 1002);
  assert.equal(lines.length, 3);
});

t('a feature slug is cut to its pattern, and a status off its list is an error', async () => {
  const h = await load();
  h.forgetFolds();
  const lines = [];
  h.record('vision', 'Plant Photos! (the long one) ' + 'x'.repeat(60), { status: 'oops' }, (l) => lines.push(l), 1000);
  const m = /feature=([^ ]+) status=([^ ]+)/.exec(lines[0]);
  assert.match(m[1], /^[a-z0-9-]{1,40}$/);
  assert.equal(m[2], 'error');
  assert.equal(h.featureOf('???'), 'app');
});

t('the app\'s own caught error writes its kind, never its message', async () => {
  const h = await load();
  h.forgetFolds();
  const seen = [];
  const log = console.log;
  console.log = (l) => seen.push(l);
  try {
    h.failed('watering-reminders', new TypeError('could not water the tomatoes at 6 AM'));
  } finally {
    console.log = log;
  }
  assert.deepEqual(seen, ['sipnship live/1 service=app feature=watering-reminders status=error reason=TypeError count=1']);
});

t('the template names no studio project and holds no developer note in its line', () => {
  const text = fs.readFileSync(file, 'utf8');
  assert.ok(!/sipnship\.dev|Pawper|Bitblitzin/i.test(text.replace(/sipnship live\/1/g, '').replace(/@sipnship/g, '')));
});
