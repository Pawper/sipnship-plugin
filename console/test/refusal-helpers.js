'use strict';
// Shared by the refusal report tests: a project folder holding the two logs
// from a fixture, a home with a token, and a fake SipNShip.
const fs = require('fs');
const os = require('os');
const http = require('http');
const path = require('path');
const tokens = require('../tokens');

const FIXTURES = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'refusal-report');
const TOKEN = 'sns_repo_' + 'B'.repeat(43);
const NOW = Date.parse('2026-11-02T18:00:00Z');

/** A folder with a .git marker and the logs of one fixture pair ("maya" or "command"). */
function project(name = 'maya') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-refusal-'));
  fs.mkdirSync(path.join(root, '.git'));
  fs.mkdirSync(path.join(root, '.scratch'));
  fs.copyFileSync(path.join(FIXTURES, `${name}-hooks.tsv`), path.join(root, '.scratch', 'hooks.log'));
  fs.copyFileSync(path.join(FIXTURES, `${name}-resolved.tsv`), path.join(root, '.scratch', 'hooks-resolved.log'));
  return root;
}

/** Environment with a home that holds a token for acme/garden (repository 42), or none. */
function envFor(url, withToken = true, extra = {}) {
  const env = { SIPNSHIP_HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sns-refusal-home-')), SIPNSHIP_URL: url, ...extra };
  if (withToken) tokens.put({ repoId: 42, fullName: 'acme/garden', token: TOKEN, machine: 'porch' }, env);
  return env;
}

/** A fake service: each request gets the next reply in the list (the last repeats). */
function fake(replies) {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body });
      const r = replies[Math.min(seen.length - 1, replies.length - 1)];
      const go = () => { res.writeHead(r.status, { 'content-type': 'application/json' }); res.end(typeof r.body === 'string' ? r.body : JSON.stringify(r.body || {})); };
      if (r.delay) setTimeout(go, r.delay).unref(); else go();
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}

/** Replies that keep every id they are sent. */
const keep = (ids) => ({ status: 200, body: { ids } });

module.exports = { project, envFor, fake, keep, FIXTURES, TOKEN, NOW };
