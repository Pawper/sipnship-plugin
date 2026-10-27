'use strict';
// Tests for the permissions step: the merge with rules already there, the
// default answers, and the refusal without a terminal.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const p = require('../permissions');

const fx = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'permissions');

test('merges with the rules already there, never replacing them', () => {
  const existing = JSON.parse(fs.readFileSync(path.join(fx, 'existing-settings.json'), 'utf8'));
  const merged = p.mergeSettings(existing, ['Bash(sh scripts/pr-open.sh:*)', 'Bash(sh scripts/ci/merge-queue.sh:*)']);
  assert.equal(merged.model, 'kept');
  assert.deepEqual(merged.permissions.deny, ['Bash(curl:*)']);
  assert.deepEqual(merged.permissions.allow, ['Bash(npm test:*)', 'Bash(sh scripts/pr-open.sh:*)', 'Bash(sh scripts/ci/merge-queue.sh:*)']);
  assert.deepEqual(existing.permissions.allow, ['Bash(npm test:*)', 'Bash(sh scripts/pr-open.sh:*)']);
});

test('starts the file when there is none', () => {
  assert.deepEqual(p.mergeSettings(undefined, ['Bash(sh status/check.sh:*)']), { permissions: { allow: ['Bash(sh status/check.sh:*)'] } });
});

test('deploy defaults to asking, the rest to yes', () => {
  const deploy = p.RULES.find((r) => r.id === 'deploy');
  assert.equal(p.answer(deploy, ''), false);
  assert.equal(p.answer(deploy, 'y'), true);
  for (const r of p.RULES.filter((x) => x.id !== 'deploy')) {
    assert.equal(p.answer(r, ''), true);
    assert.equal(p.answer(r, 'no'), false);
  }
});

test('the rules match the template file', () => {
  const tpl = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'templates', '.claude', 'settings.json'), 'utf8'));
  assert.deepEqual(p.RULES.flatMap((r) => r.allow).sort(), tpl.permissions.allow.slice().sort());
});

test('refuses without a terminal, with the plain sentence and the command', async () => {
  assert.equal(p.refusal(true), null);
  assert.match(p.refusal(false), /not allowed to grant itself permissions/);
  let said = '';
  const io = { stdin: { isTTY: false }, stdout: { isTTY: false, write() {} }, stderr: { write(s) { said += s; } } };
  assert.equal(await p.run(fx, io), 2);
  assert.equal(said, p.WHY + '\n');
  assert.ok(said.includes(p.COMMAND));
});
