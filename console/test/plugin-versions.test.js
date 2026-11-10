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
