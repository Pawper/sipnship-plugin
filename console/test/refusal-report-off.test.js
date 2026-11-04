'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const report = require('../refusal-report');
const { project, envFor, fake, NOW } = require('./refusal-helpers');

const OFF = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'refusal-report', 'maya-off.tsv');
const OFF_IDS = ['2026-11-02T17:05:00Z-5001', '2026-11-02T17:20:00Z-5120'];

/** A project with no settled refusals, only the notes a rule that was off left. */
function offProject() {
  const root = project();
  fs.writeFileSync(path.join(root, '.scratch', 'hooks.log'), '');
  fs.writeFileSync(path.join(root, '.scratch', 'hooks-resolved.log'), '');
  fs.copyFileSync(OFF, path.join(root, '.scratch', 'hooks-off.log'));
  return root;
}

test('a note from a rule that was off becomes an off report with no command, seconds or tool', () => {
  const reports = report.offReportsFrom(fs.readFileSync(OFF, 'utf8'), { repoId: 42, now: NOW });
  assert.deepStrictEqual(reports.map((r) => r.id), OFF_IDS);
  assert.deepStrictEqual(reports[0], { id: OFF_IDS[0], rule: 'block-delete', at: '2026-11-02T17:05:00Z', outcome: 'off', after: 0, calls: 0, session: report.sessionKey('sess-maya-1', 42) });
  assert.ok(report.OUTCOMES.includes('off'));
});

test('a note without an id, or older than 30 days, is left out', () => {
  assert.deepStrictEqual(report.offReportsFrom('2026-11-02T17:05:00Z\tblock-delete\tnever-delete\tsess-maya-1\n', { repoId: 42, now: NOW }), []);
  assert.deepStrictEqual(report.offReportsFrom(fs.readFileSync(OFF, 'utf8'), { repoId: 42, now: NOW + 40 * 86400000 }), []);
});

test('off reports are sent once and keep a cursor of their own', async () => {
  const f = await fake([{ status: 200, body: { ids: OFF_IDS } }]);
  const root = offProject();
  const env = envFor(f.url);
  await report.sendNow({ root, repo: 'acme/garden', session: 'sess-maya-1', env, now: NOW });
  assert.deepStrictEqual(JSON.parse(f.seen[0].body).reports.map((r) => r.outcome), ['off', 'off']);
  assert.strictEqual(fs.readFileSync(path.join(root, '.scratch', 'hooks', 'sent-off'), 'utf8').trim(), OFF_IDS[1]);
  assert.strictEqual(fs.existsSync(path.join(root, '.scratch', 'hooks', 'sent')), false);
  await report.sendNow({ root, repo: 'acme/garden', session: 'sess-maya-1', env, now: NOW });
  assert.strictEqual(f.seen.length, 1);
  f.server.close();
});
