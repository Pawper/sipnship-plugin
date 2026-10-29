'use strict';
// Tests for the Runners card. Run with: node --test console/test/runners.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const runners = require('../runners');
const render = require('../render');

const now = 1800000000;
const row = (ago, busy, total, mins) => `${now - ago}\t-\trun 1: test\t${busy}\t${total}\t${mins}`;

test('the waits line counts this week only, with the longest wait', () => {
  const text = [row(9 * 86400, 3, 3, 30), row(3600, 3, 3, 2), row(7200, 3, 3, 4), row(86400, 3, 3, 1)].join('\n');
  assert.equal(runners.waitsLine(text, now), 'Jobs waited for a runner 3 times this week, 4 minutes at most, when all 3 were busy.');
});

test('the waits line says nothing without a wait this week', () => {
  assert.equal(runners.waitsLine('', now), '');
  assert.equal(runners.waitsLine(row(8 * 86400, 3, 3, 5), now), '');
});

test('the waits line says when not every runner was busy', () => {
  assert.equal(runners.waitsLine(row(60, 2, 3, 1), now), 'Jobs waited for a runner once this week, 1 minute at most, with up to 2 of 3 busy.');
});

test('the machine fact is over the rule past one runner per two cores', () => {
  assert.equal(runners.machineFact(`${now}\t16\t9\t2\tL`).over, true);
  assert.equal(runners.machineFact(`${now}\t16\t8\t2\tL`).over, false);
  assert.equal(runners.machineFact(''), null);
});

test('no card when there is nothing to say', () => {
  assert.equal(runners.runnersCard('', '', now), null);
});

test('the Runners card renders in the console card form', () => {
  const card = runners.runnersCard(row(60, 3, 3, 4), `${now}\t16\t9\t2\t16 cores, 9 runner(s) on this machine across repositories, 2 busy now; the rule allows 8 (one per two cores)`, now);
  const html = render.renderCard(card);
  assert.match(html, /<section class="card" id="runners">/);
  assert.match(html, /<h3>Runners<\/h3>/);
  assert.match(html, /Jobs waited for a runner once this week, 4 minutes at most, when all 3 were busy\./);
  assert.match(html, /This machine: 16 cores, 9 runner\(s\) on this machine across repositories, 2 busy now; the rule allows 8 \(one per two cores\)\./);
  assert.match(html, /class="state partly"/);
});

test('the card reads the two local files', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'runners-'));
  fs.mkdirSync(path.join(dir, '.scratch', 'queue'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.scratch', 'queue', 'waits.tsv'), `${Math.floor(Date.now() / 1000) - 60}\t-\tjob\t3\t3\t4\n`);
  const card = runners.readRunnersCard(dir, dir, Math.floor(Date.now() / 1000));
  assert.equal(card.does, 'Jobs waited for a runner once this week, 4 minutes at most, when all 3 were busy.');
  assert.equal(card.note, '');
});
