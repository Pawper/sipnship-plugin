'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const report = require('../refusal-report');
const { project, NOW, FIXTURES } = require('./refusal-helpers');

const read = (name) => fs.readFileSync(path.join(FIXTURES, name), 'utf8');
const FIELDS = ['id', 'rule', 'at', 'outcome', 'after', 'calls', 'via', 'issues', 'session'];

test('the body carries only the fields of the spec, each value from its list, a time or a count', () => {
  const reports = report.reportsFrom(read('maya-hooks.tsv'), read('maya-resolved.tsv'), { repoId: 42, now: NOW });
  // the fourth refusal never settled, so it is not reported
  assert.deepStrictEqual(reports.map((r) => r.id), ['2026-11-02T16:10:00Z-4121', '2026-11-02T16:40:00Z-4377', '2026-11-02T16:50:00Z-4390']);
  for (const r of reports) {
    for (const k of Object.keys(r)) assert.ok(FIELDS.includes(k), `unexpected field ${k}`);
    assert.match(r.rule, /^[a-z][a-z0-9-]+$/);
    assert.match(r.at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.ok(report.OUTCOMES.includes(r.outcome));
    assert.ok(Number.isInteger(r.after) && r.after >= 0);
    assert.ok(Number.isInteger(r.calls) && r.calls >= 0 && r.calls <= 5);
    assert.match(r.session, /^[0-9a-f]{16}$/);
  }
  assert.deepStrictEqual(reports[0], { id: '2026-11-02T16:10:00Z-4121', rule: 'block-delete', at: '2026-11-02T16:10:00Z', outcome: 'followed', after: 14, calls: 1, session: report.sessionKey('sess-maya-1', 42) });
  assert.strictEqual(reports[1].via, 'shell');
  assert.strictEqual(reports[0].via, undefined);
});

test('a log line that somehow holds a command still sends none of it', () => {
  const reports = report.reportsFrom(read('command-hooks.tsv'), read('command-resolved.tsv'), { repoId: 42, now: NOW });
  const text = JSON.stringify(reports);
  for (const word of ['rm', 'frost', 'python', 'os.remove', 'git mv', 'extra', 'aside']) assert.ok(!text.includes(word), `the body holds "${word}"`);
  // the line whose hook field holds text is dropped whole; the one whose via is text keeps no via
  assert.deepStrictEqual(reports.map((r) => r.id), ['2026-11-02T16:10:00Z-4121', '2026-11-02T16:50:00Z-4390']);
  assert.strictEqual(reports[1].via, undefined);
});

test('the session key cannot be matched to the session id, and differs by repository', () => {
  const a = report.sessionKey('sess-maya-1', 42);
  assert.match(a, /^[0-9a-f]{16}$/);
  assert.ok(!a.includes('maya') && !JSON.stringify(report.reportsFrom(read('maya-hooks.tsv'), read('maya-resolved.tsv'), { repoId: 42, now: NOW })).includes('sess-maya'));
  assert.notStrictEqual(a, report.sessionKey('sess-maya-1', 43));
  assert.notStrictEqual(a, report.sessionKey('sess-maya-2', 42));
  assert.strictEqual(a, report.sessionKey('sess-maya-1', 42));
});

test('what waits starts after the cursor, oldest first, and never reaches past 200 or 30 days', () => {
  const root = project();
  assert.strictEqual(report.pending(root, 42, NOW).length, 3);
  fs.mkdirSync(path.join(root, '.scratch', 'hooks'));
  fs.writeFileSync(path.join(root, '.scratch', 'hooks', 'sent'), '2026-11-02T16:40:00Z-4377\n');
  assert.deepStrictEqual(report.pending(root, 42, NOW).map((r) => r.id), ['2026-11-02T16:50:00Z-4390']);
  // 30 days on, the three are too old to send
  assert.deepStrictEqual(report.pending(project(), 42, NOW + 31 * 24 * 3600 * 1000), []);
  // a long log: at most 200, from the oldest
  const big = project();
  const hooks = []; const resolved = [];
  for (let i = 0; i < 250; i++) {
    const t = `2026-11-02T16:${String(10 + Math.floor(i / 60)).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}Z`;
    hooks.push(`${t}\tblock-delete\tsess-maya-1\t${t}-${1000 + i}`);
    resolved.push(`${t}\t${t}-${1000 + i}\tblock-delete\tsess-maya-1\tfollowed\t1\t1\t`);
  }
  fs.writeFileSync(path.join(big, '.scratch', 'hooks.log'), hooks.join('\n') + '\n');
  fs.writeFileSync(path.join(big, '.scratch', 'hooks-resolved.log'), resolved.join('\n') + '\n');
  const sent = report.pending(big, 42, NOW);
  assert.strictEqual(sent.length, report.MAX_REPORTS);
  assert.strictEqual(sent[0].id, '2026-11-02T16:10:00Z-1000');
});
