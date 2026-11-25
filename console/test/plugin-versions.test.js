'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const versions = require('../plugin-versions');
const send = require('../brief-send');

function folder() { return fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'pv-')); }

test('the three versions come from the installed copy, the cached release and the repository', () => {
  const root = folder();
  const home = folder();
  fs.mkdirSync(path.join(root, 'plugin', '.claude-plugin'), { recursive: true });
  fs.writeFileSync(path.join(root, 'plugin', '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'x', version: '0.45.0' }));
  fs.mkdirSync(path.join(home, 'brief-cache', 'rooftop-garden'), { recursive: true });
  fs.writeFileSync(path.join(home, 'brief-cache', 'rooftop-garden', 'plugin-versions'), 'released=0.44.0 user=0.43.2 project=\n');
  const got = versions.read({ root, env: { SIPNSHIP_HOME: home } });
  assert.strictEqual(got.released, '0.44.0');
  assert.strictEqual(got.repository, '0.45.0');
  assert.match(got.installed, /^\d+\.\d+\.\d+$/);
});

test('a version that is not known is left out, and none at all is nothing', () => {
  const root = folder();
  const home = folder();
  const got = versions.read({ root, env: { SIPNSHIP_HOME: home } });
  assert.strictEqual(got.released, undefined);
  assert.strictEqual(got.repository, undefined);
  assert.strictEqual(versions.versionOf(path.join(root, 'missing.json')), undefined);
});

test('the brief body carries the versions only when it is given them', () => {
  const withIt = send.briefBody('', { plugin: { installed: '0.43.2', released: '0.44.0' } });
  assert.deepStrictEqual(withIt.plugin, { installed: '0.43.2', released: '0.44.0' });
  assert.strictEqual('plugin' in send.briefBody('', {}), false);
});

// #2703: how far the project's shipped files are behind, kept by the last sync report and used only while it still holds.
test('the shipped counts come from the last sync report while its commit and version still hold, else nothing', () => {
  const { execFileSync } = require('child_process');
  const root = folder();
  const git = (...a) => execFileSync('git', ['-c', 'user.email=maya@example.com', '-c', 'user.name=Maya', ...a], { cwd: root, encoding: 'utf8' }).trim();
  git('init', '-q');
  git('commit', '-q', '--allow-empty', '-m', 'Start the rooftop-garden app');
  const keep = (over) => fs.writeFileSync(path.join(root, '.git', 'sipnship-shipped.json'), JSON.stringify({ head: git('rev-parse', 'HEAD'), version: '0.43.1', older: 14, edited: 2, ...over }));
  keep({});
  assert.deepStrictEqual(versions.shippedFrom(root, '0.43.1'), { older: 14, edited: 2 });
  assert.strictEqual(versions.shippedFrom(root, '0.43.2'), undefined);
  keep({ head: 'abc' });
  assert.strictEqual(versions.shippedFrom(root, '0.43.1'), undefined);
  keep({ older: 'many' });
  assert.strictEqual(versions.shippedFrom(root, '0.43.1'), undefined);
  assert.strictEqual(versions.shippedFrom(folder(), '0.43.1'), undefined);
});

// #2703: a plugin copy old enough to have no known-hash list at all cannot judge any file, so the sync reports
// the item as "beyond the list" (older and edited both 0) rather than a guessed count, and the flag carries through.
test('beyond the list carries through; a normal count does not carry a flag it was never given', () => {
  const { execFileSync } = require('child_process');
  const root = folder();
  const git = (...a) => execFileSync('git', ['-c', 'user.email=maya@example.com', '-c', 'user.name=Maya', ...a], { cwd: root, encoding: 'utf8' }).trim();
  git('init', '-q');
  git('commit', '-q', '--allow-empty', '-m', 'Start the rooftop-garden app');
  const keep = (over) => fs.writeFileSync(path.join(root, '.git', 'sipnship-shipped.json'), JSON.stringify({ head: git('rev-parse', 'HEAD'), version: '0.43.1', older: 0, edited: 0, ...over }));
  keep({ beyondList: true });
  assert.deepStrictEqual(versions.shippedFrom(root, '0.43.1'), { older: 0, edited: 0, beyondList: true });
  keep({ older: 14, edited: 2 });
  assert.deepStrictEqual(versions.shippedFrom(root, '0.43.1'), { older: 14, edited: 2 });
});
