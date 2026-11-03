'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { askWindow, hasScreen, windowCommand, titleFor, SENTENCE } = require('../ask-window');
const tokens = require('../tokens');
const listen = require('../listen');

const T = 'sns_repo_' + 'Q'.repeat(43);
const sink = () => { const s = { text: '', write: (t) => { s.text += t; } }; return s; };

test('the window asks the listener question with Yes and No, and No is the default button', () => {
  const win = windowCommand(titleFor("Maya's desktop"), SENTENCE, 'win32');
  const script = win.args[win.args.length - 1];
  assert.match(script, /YesNo/);
  assert.match(script, /Button2/);
  assert.match(script, /Let Maya''s desktop carry out what you ask\?/);
  assert.match(script, /It only does what you approve there, one thing at a time/);
  const mac = windowCommand('t', 's', 'darwin');
  assert.match(mac.args[1], /default button "No"/);
  assert.strictEqual(windowCommand('t', 's', 'linux'), null);
});

test('only a Yes pressed in the window is a yes', () => {
  const answer = (stdout, status = 0) => askWindow({ machine: 'x', screen: true, platform: 'win32', run: () => ({ status, stdout }) });
  assert.strictEqual(answer('Yes\n'), true);
  assert.strictEqual(answer('No\n'), false);
  assert.strictEqual(answer(''), false);
  assert.strictEqual(answer('Yes', 1), false);
  assert.strictEqual(askWindow({ screen: true, platform: 'win32', run: () => { throw new Error('no window tool'); } }), false);
});

test('with no screen nothing is asked and the answer is No', () => {
  let asked = false;
  const run = () => { asked = true; return { status: 0, stdout: 'Yes' }; };
  assert.strictEqual(askWindow({ env: { SSH_CONNECTION: '1 2 3 4' }, platform: 'win32', run }), false);
  assert.strictEqual(askWindow({ env: {}, platform: 'linux', run }), false);
  assert.strictEqual(asked, false);
  assert.strictEqual(hasScreen({ SSH_TTY: '/dev/pts/0' }, 'darwin'), false);
  assert.strictEqual(hasScreen({}, 'win32'), true);
});

test('the connect question and listen on turn the listener on only after a Yes in the window', async () => {
  const scratch = path.resolve(__dirname, '..', '..', '..', '.scratch');
  fs.mkdirSync(scratch, { recursive: true });
  const env = { SIPNSHIP_HOME: fs.mkdtempSync(path.join(scratch, 'sns-window-')) };
  try {
    tokens.put({ repoId: 42, fullName: 'maya/rooftop-garden', token: T, machine: "Maya's desktop" }, env);
    const out = sink();
    let seen;
    assert.strictEqual(await listen.offerOn({ env, out, repo: 'maya/rooftop-garden', window: (o) => { seen = o.machine; return false; } }), false);
    assert.strictEqual(seen, "Maya's desktop");
    assert.strictEqual(listen.readState(env).on, false);
    assert.strictEqual(await listen.offerOn({ env, out, repo: 'maya/rooftop-garden', cwd: process.cwd(), register: () => false, window: () => true }), true);
    assert.strictEqual(listen.readState(env).on, true);
  } finally {
    fs.rmSync(env.SIPNSHIP_HOME, { recursive: true, force: true });
  }
});
