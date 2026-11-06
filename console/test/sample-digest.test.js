'use strict';
// The digest a tool call's send is gated on: it moves when a session's last
// line or its ended state does, not when only its log grows, and it reads no
// more than the end of each log. Logs from a session of Maya's rooftop-garden app.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const sessions = require('../sessions');
const { digest, lastLineIn, lastTimeIn, TAIL_BYTES } = require('../sample-digest');
const { freshLog } = require('./fresh-log');

const fx = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'sessions', 'watering-session.jsonl');
const said = (text) => JSON.stringify({ type: 'assistant', timestamp: new Date().toISOString(), message: { role: 'assistant', content: [{ type: 'text', text }] } }) + '\n';
const tool = (n) => JSON.stringify({ type: 'user', timestamp: new Date().toISOString(), message: { role: 'user', content: [{ type: 'tool_result', content: 'x'.repeat(n) }] } }) + '\n';

function folder() {
  const tree = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-dg-tree-'));
  const logs = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-dg-logs-'));
  const dir = path.join(logs, sessions.logFolder(tree));
  fs.mkdirSync(dir, { recursive: true });
  const log = path.join(dir, 'garden.jsonl');
  // Written as now, as a working session's is: the fixture's own times are days old.
  freshLog(fx, log);
  const endedFile = path.join(logs, 'ended.tsv');
  return { log, dir, at: () => digest({ worktrees: [tree], logsDir: logs, endedFile }), endedFile };
}

test('the digest moves with a new line and an agent ending, not with a tool result', () => {
  const f = folder();
  const first = f.at();
  fs.appendFileSync(f.log, tool(200));
  assert.strictEqual(f.at(), first, 'a tool result says nothing new');
  fs.appendFileSync(f.log, said('Moving the frost check into the schedule helper.'));
  const second = f.at();
  assert.notStrictEqual(second, first, 'a new line moves it');
  const sub = path.join(f.dir, 'garden', 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  fs.writeFileSync(path.join(sub, 'agent-a1b2.jsonl'), said('Writing the rain test.'));
  const third = f.at();
  assert.notStrictEqual(third, second, 'an agent starting moves it');
  fs.writeFileSync(f.endedFile, `a1b2\t${Math.floor(Date.now() / 1000) + 5}\n`);
  assert.notStrictEqual(f.at(), third, 'the agent ending moves it');
});

test('an old log whose date was rewritten does not move it, and an agent the runtime marks finished does', () => {
  const f = folder();
  const first = f.at();
  const sub = path.join(f.dir, 'garden', 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  const old = path.join(sub, 'agent-c3d4.jsonl');
  freshLog(fx, old, Date.now() - 10 * 24 * 3600 * 1000);
  fs.utimesSync(old, new Date(), new Date());
  assert.strictEqual(f.at(), first, 'its last entry is days old: not in the digest');
  freshLog(fx, path.join(sub, 'agent-e5f6.jsonl'));
  const running = f.at();
  assert.notStrictEqual(running, first);
  fs.writeFileSync(path.join(sub, 'agent-e5f6.meta.json'), JSON.stringify({ finished: true }));
  assert.notStrictEqual(f.at(), running, 'the runtime marking it finished moves it');
  assert.strictEqual(lastTimeIn('{"timestamp":"2026-11-05T21:00:00.000Z"}\n{"type":"tools-used"}\n', true), Date.parse('2026-11-05T21:00:00.000Z'));
});

test('only the end of a log is read: a line said before a long tool result is not found, and the cut line is dropped', () => {
  const text = said('Earlier words.') + tool(TAIL_BYTES * 2);
  assert.strictEqual(lastLineIn(text.slice(-TAIL_BYTES), false), '');
  assert.strictEqual(lastLineIn(said('Twelve words at most: one two three four five six seven eight nine ten'), true), 'Twelve words at most: one two three four five six seven eight…');
});
