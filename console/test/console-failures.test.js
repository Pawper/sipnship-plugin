'use strict';
// A failed console part names the failing case in its own log. Two test files
// of a sample project's watering reminders run on their own: one with a failing
// assertion, one whose cases all pass but whose process ends badly (what a
// crash at exit looks like). The report must name both.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const script = path.join(__dirname, '..', '..', 'tests', 'console-failures.sh');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-failures-'));

function report(files) {
  // This file runs under the test runner; the sample run must start as a run of its own.
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  const run = spawnSync(process.execPath, ['--test', '--test-reporter', 'tap', ...files], { encoding: 'utf8', env });
  const log = path.join(tmp, 'tap.txt');
  fs.writeFileSync(log, run.stdout + (run.stderr || ''));
  return spawnSync('sh', [script, log], { encoding: 'utf8' }).stdout;
}

test('a failing assertion is reported with its case name and its message', () => {
  const file = path.join(tmp, 'water.test.js');
  fs.writeFileSync(file, [
    "const test = require('node:test');",
    "const assert = require('node:assert');",
    "test('rain skips the bed', () => {});",
    "test('the tomato bed is watered on dry days', () => { assert.strictEqual(1, 2, 'tomatoes were skipped'); });",
  ].join('\n'));
  const out = report([file]);
  assert.match(out, /not ok \d+ - the tomato bed is watered on dry days/);
  assert.match(out, /tomatoes were skipped/);
  assert.doesNotMatch(out, /rain skips the bed/);
});

test('a test file that ends badly after passing every case is reported with its name and exit code', () => {
  const file = path.join(tmp, 'reminders.test.js');
  fs.writeFileSync(file, [
    "const test = require('node:test');",
    "test('the reminder is sent', () => {});",
    "process.on('exit', () => { process.exitCode = 3; console.error('the reminder queue closed early'); });",
  ].join('\n'));
  const out = report([file]);
  assert.match(out, /not ok \d+ - .*reminders\.test\.js/);
  assert.match(out, /exitCode: 3/);
  assert.match(out, /the reminder queue closed early/);
});
