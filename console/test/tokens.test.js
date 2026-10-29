'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const tokens = require('../tokens');

const T = 'sns_repo_' + 'A'.repeat(43);
const T2 = 'sns_repo_' + 'b_-'.repeat(14) + 'c';
const envAt = () => ({ SIPNSHIP_HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sns-tokens-')) });

test('an empty store reads as no repositories', () => {
  assert.deepStrictEqual(tokens.read(envAt()), { version: 1, repos: {} });
});

test('a token is kept under SIPNSHIP_HOME, keyed by the repository id, and found by id or name', () => {
  const env = envAt();
  tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, env);
  assert.strictEqual(tokens.file(env), path.join(env.SIPNSHIP_HOME, 'tokens.json'));
  const raw = JSON.parse(fs.readFileSync(tokens.file(env), 'utf8'));
  assert.strictEqual(raw.repos['42'].token, T);
  assert.strictEqual(tokens.find(42, env).fullName, 'acme/shop');
  assert.strictEqual(tokens.find('ACME/Shop', env).repoId, 42);
  assert.strictEqual(tokens.find('acme/other', env), undefined);
});

test('a second token for the same repository replaces the first; others stay', () => {
  const env = envAt();
  tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, env);
  tokens.put({ repoId: 7, fullName: 'acme/blog', token: T, machine: 'desk' }, env);
  tokens.put({ repoId: 42, fullName: 'acme/shop', token: T2, machine: 'desk' }, env);
  assert.strictEqual(tokens.find(42, env).token, T2);
  assert.strictEqual(tokens.find(7, env).token, T);
});

test('remove forgets one repository and says whether there was one', () => {
  const env = envAt();
  tokens.put({ repoId: 42, fullName: 'acme/shop', token: T, machine: 'desk' }, env);
  assert.strictEqual(tokens.remove(42, env), true);
  assert.strictEqual(tokens.remove(42, env), false);
  assert.strictEqual(tokens.find(42, env), undefined);
});

test('only a real token shape is kept', () => {
  assert.throws(() => tokens.put({ repoId: 1, fullName: 'a/b', token: 'ghp_x', machine: 'm' }, envAt()));
  assert.throws(() => tokens.put({ repoId: 0, fullName: 'a/b', token: T, machine: 'm' }, envAt()));
});

test('an unreadable file reads as empty rather than failing', () => {
  const env = envAt();
  fs.writeFileSync(tokens.file(env), 'not json');
  assert.deepStrictEqual(tokens.read(env).repos, {});
});

test('the repository is read from a GitHub remote', () => {
  assert.strictEqual(tokens.repoFromRemote('https://github.com/acme/shop.git\n'), 'acme/shop');
  assert.strictEqual(tokens.repoFromRemote('git@github.com:acme/shop.git'), 'acme/shop');
  assert.strictEqual(tokens.repoFromRemote('https://gitlab.com/acme/shop'), undefined);
});
