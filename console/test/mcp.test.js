'use strict';
// The plugin's setup MCP server: it lists the one tool, reads the checklist in
// the dashboard's words through the same reading as `sipnship setup`, and is
// registered by the plugin's .mcp.json so an agent needs no manual step.
// Written as Maya's rooftop-garden app.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { handle, serve } = require('../mcp');
const { setupLines } = require('../setup');

const READING = {
  complete: false, done: 1, total: 2, advice: [],
  items: [
    { title: 'Connect Maya\'s rooftop garden', state: 'done', say: 'The repository is connected.', fields: [], handles: [] },
    { title: 'Add a runner', state: 'needs-you', turn: { words: 'Needs you' }, say: 'Builds wait for a runner.', fields: [{ label: 'Machine', value: 'Maya\'s desktop' }], handles: [] },
  ],
};
const fetchOk = async (url, init) => { fetchOk.last = { url, init }; return { ok: true, json: async () => READING }; };

test('it lists the one tool and answers ping', async () => {
  const init = await handle({ jsonrpc: '2.0', id: 1, method: 'initialize' });
  assert.equal(init.result.serverInfo.name, 'sipnship');
  const list = await handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
  assert.deepEqual(list.result.tools.map((t) => t.name), ['setup']);
  assert.deepEqual((await handle({ jsonrpc: '2.0', id: 3, method: 'ping' })).result, {});
  assert.equal(await handle({ jsonrpc: '2.0', method: 'notifications/initialized' }), undefined);
});

test('setup answers in the same words as the CLI, with the repository from the call', async () => {
  const r = await handle({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'setup', arguments: { repo: 'maya/rooftop-garden' } } }, { fetchFn: fetchOk, env: { SIPNSHIP_HOME: path.join(__dirname, 'nowhere') } });
  assert.equal(r.result.content[0].text, setupLines(READING).join('\n'));
  assert.match(fetchOk.last.url, /\/v1\/repos\/maya\/rooftop-garden\/setup$/);
  assert.equal(fetchOk.last.init.headers.authorization, undefined);
});

test('another tool, an unknown method and a missing repository are refused in plain words', async () => {
  assert.equal((await handle({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'deploy' } })).error.code, -32602);
  assert.equal((await handle({ jsonrpc: '2.0', id: 6, method: 'resources/list' })).error.code, -32601);
  const r = await handle({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'setup', arguments: { repo: 'not a repo' } } }, { fetchFn: fetchOk });
  assert.equal(r.result.isError, true);
});

test('serve reads lines and writes one reply per line', async () => {
  const out = [];
  await serve([`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' })}\nnot json\n`], { write: (s) => out.push(s) });
  assert.equal(out.length, 2);
  assert.equal(JSON.parse(out[1]).error.code, -32700);
});

test('the plugin registers the server, so an agent reaches it with no manual step', () => {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '.mcp.json'), 'utf8'));
  assert.equal(cfg.mcpServers.sipnship.command, 'node');
  assert.deepEqual(cfg.mcpServers.sipnship.args, ['${CLAUDE_PLUGIN_ROOT}/console/mcp.js']);
  assert.ok(fs.existsSync(path.join(__dirname, '..', 'mcp.js')));
});
