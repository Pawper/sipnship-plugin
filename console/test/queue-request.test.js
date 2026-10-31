'use strict';
const test = require('node:test');
const assert = require('node:assert');
const http = require('http');
const { request, issueForm } = require('../queue-request');

const sink = () => { const o = { text: '', write: (s) => { o.text += s; } }; return o; };
const run = (cmd, args) => (args[0] === 'auth' ? 'gho_person\n' : 'maya\n');

function fake(status = 201) {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body: body ? JSON.parse(body) : undefined });
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(status === 201 ? { say: 'Landing next' } : { say: 'This repository is not connected to SipNShip yet.' }));
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}` })));
}

test('land-next sends the request in the person\'s name and prints the dashboard\'s words', async () => {
  const f = await fake();
  const out = sink();
  const code = await request({ kind: 'land-next', pr: '48', reason: 'it unblocks the others', repo: 'maya/rooftop-garden', env: { SIPNSHIP_URL: f.url }, out, run });
  f.server.close();
  assert.strictEqual(code, 0);
  assert.deepStrictEqual(f.seen[0], { method: 'POST', url: '/v1/repos/maya/rooftop-garden/queue/requests', auth: 'Bearer gho_person', body: { kind: 'land-next', pr: 48, reason: 'it unblocks the others', via: 'cli' } });
  assert.match(out.text, /^Landing next\. The queue takes it within two minutes\./);
});

test('deploy-now names no pull request, and its issue form has none', async () => {
  const f = await fake();
  const code = await request({ kind: 'deploy-now', reason: 'the frost alert copy', repo: 'maya/rooftop-garden', env: { SIPNSHIP_URL: f.url }, out: sink(), run });
  f.server.close();
  assert.strictEqual(code, 0);
  assert.deepStrictEqual(f.seen[0].body, { kind: 'deploy-now', reason: 'the frost alert copy', via: 'cli' });
  assert.strictEqual(issueForm('deploy-now', 0, 'maya', 'the frost alert copy'), 'Queue request: deploy-now by maya: the frost alert copy');
});

test('drop needs a reason, and a number is required', async () => {
  const out = sink();
  assert.strictEqual(await request({ kind: 'drop', pr: 51, repo: 'maya/rooftop-garden', out, run }), 2);
  assert.match(out.text, /say why/);
  assert.strictEqual(await request({ kind: 'hold', pr: 'the planter grid', repo: 'maya/rooftop-garden', out: sink(), run }), 2);
});

test('when SipNShip cannot be reached, it prints the issue form the queue reads', async () => {
  const out = sink();
  const code = await request({ kind: 'drop', pr: 51, reason: 'the seed catalog moved', repo: 'maya/rooftop-garden', env: { SIPNSHIP_URL: 'http://127.0.0.1:1' }, out, run });
  assert.strictEqual(code, 1);
  assert.match(out.text, /Queue request: drop #51 by maya: the seed catalog moved/);
  assert.strictEqual(issueForm('hold', 48, 'maya', ''), 'Queue request: hold #48 by maya');
});
