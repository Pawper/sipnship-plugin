#!/usr/bin/env node
'use strict';
// The setup tool as an MCP server, over stdio, so an agent reaches it with no
// manual step: the plugin's .mcp.json starts this file when the plugin is on.
// One JSON message per line in, one per line out. It answers only
// initialize, ping, tools/list and tools/call for the one tool it lists,
// `setup`, which reads the checklist from the service in the dashboard's own
// words (the same reading `sipnship setup` prints) with the token this
// machine holds for the repository, never printing the token. Read-only.

const tokens = require('./tokens');
const { base } = require('./brief-send');
const { remoteRepo } = require('./connect');
const { readSetup } = require('./setup');

const PROTOCOL_VERSION = '2024-11-05';
const SERVER_INFO = { name: 'sipnship', version: '0.0.0' };
const TOOL = {
  name: 'setup',
  description: 'How setting up this project is going: each item with its state, whose turn it is, one plain sentence, its fields and its handle, in the words the dashboard shows. Read-only.',
  inputSchema: { type: 'object', properties: { repo: { type: 'string', description: 'The repository, as owner/name. Left out, the current folder\'s repository.' } }, additionalProperties: false },
};

const reply = (id, result) => ({ jsonrpc: '2.0', id, result });
const refuse = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
const asText = (text, isError) => ({ ...(isError ? { isError: true } : {}), content: [{ type: 'text', text }] });

async function callSetup(args, { env = process.env, cwd = process.cwd(), fetchFn = (u, i) => fetch(u, { ...i, signal: AbortSignal.timeout(15000) }) } = {}) {
  const given = args && typeof args.repo === 'string' ? args.repo.trim() : '';
  const repo = given || remoteRepo(cwd);
  if (!repo || !/^[\w.-]+\/[\w.-]+$/.test(repo)) return asText('Say which repository, as owner/name.', true);
  const entry = tokens.find(repo, env);
  const answer = await readSetup(fetchFn, base(env), repo, entry && entry.token);
  return answer.ok ? { ...asText(answer.text), structuredContent: answer.reading } : asText(answer.text, true);
}

async function handle(m, ctx = {}) {
  if (!m || m.id === undefined) return undefined;
  switch (m.method) {
    case 'initialize':
      return reply(m.id, { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: SERVER_INFO });
    case 'ping':
      return reply(m.id, {});
    case 'tools/list':
      return reply(m.id, { tools: [TOOL] });
    case 'tools/call':
      if (!m.params || m.params.name !== TOOL.name) return refuse(m.id, -32602, 'That tool is not here. The one tool is setup.');
      return reply(m.id, await callSetup(m.params.arguments || {}, ctx));
    default:
      return refuse(m.id, -32601, 'This server answers only initialize, ping, tools/list and tools/call.');
  }
}

async function serve(input, output, ctx = {}) {
  let buffer = '';
  const run = async (line) => {
    if (!line.trim()) return;
    let m;
    try { m = JSON.parse(line); } catch { output.write(`${JSON.stringify(refuse(null, -32700, 'That was not a JSON message.'))}\n`); return; }
    const r = await handle(m, ctx);
    if (r) output.write(`${JSON.stringify(r)}\n`);
  };
  for await (const chunk of input) {
    buffer += chunk.toString();
    let at;
    while ((at = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, at);
      buffer = buffer.slice(at + 1);
      await run(line);
    }
  }
  await run(buffer);
}

module.exports = { handle, serve, callSetup, TOOL };

if (require.main === module) serve(process.stdin, process.stdout).catch(() => { process.exitCode = 1; });
